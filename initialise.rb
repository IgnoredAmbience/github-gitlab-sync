require 'bundler/setup'
require 'netrc'
require 'tmpdir'

ENV['GITLAB_API_ENDPOINT'] ||= 'https://gitlab.doc.ic.ac.uk/api/v3'

require 'gitlab'
require 'octokit'
require 'rugged'
require 'pry'

#stack = Faraday::RackBuilder.new do |builder|
#  builder.response :logger
#  builder.use Octokit::Response::RaiseError
#  builder.adapter Faraday.default_adapter
#end
#Octokit.middleware = stack

#module Gitlab
#  class Client
#    # So we can do the initial token setup
#    attr_accessor :username
#    attr_writer :password
#
#    def create_auth_token
#      endpoint = URI(self.endpoint)
#      endpoint.path = "/oauth/token"
#      result = HTTParty.post(endpoint, :format => :json, :body => {
#        :grant_type => :password,
#        :username   => @username,
#        :password   => @password
#      })
#      self.private_token = result.access_token
#    end
#  end
#end

class Sync
  def initialize
    @netrc = Netrc.read
    @github = Octokit::Client.new(:netrc => false)

    @gitlab = Gitlab::Client.new(:private_token => "blah")
    @gitlab_bot = Gitlab::Client.new(:private_token => "blah2")
  end

  def run
    github_login
    gitlab_login

    source_repo = Octokit::Repository.new(prompt "username/name of GitHub repo to sync from:")
    source_repo_detail = @github.repo source_repo
    dest_repo   = @gitlab.project prompt("username/name of GitLab repo to sync to:", source_repo.slug).gsub("/", "%2F")

    Dir.mktmpdir("git-sync-") {|dir|
      ## Project configuration
      ssh_key = ssh_keygen "#{dir}/key"

      # Install public keys for r/w access
      @gitlab_bot.create_ssh_key "GitHub GitLab Sync Public Key (#{dest_repo.path_with_namespace})", ssh_key[:publickey_text]
      @github.add_deploy_key source_repo, "GitHub GitLab Sync Public Key", ssh_key[:publickey_text]

      # Add the Gitlab Bot user as a developer
      @gitlab.add_team_member(dest_repo.id, @gitlab_bot.user.id, 30)

      ## Git repo sync and modification
      # Clone GitHub
      creds = Rugged::Credentials::SshKey.new(ssh_key)
      repo_dir = dir + '/repo'
      clone = Rugged::Repository.clone_at(source_repo_detail.ssh_url, repo_dir, :credentials => creds)

      # Add GitLab remote
      remote = clone.remotes.create('gitlab', dest_repo.ssh_url_to_repo)
      remote.fetch(:credentials => creds)

      # Sync
      local_branches = sync_remotes_to_local clone

      # Checkout master
      clone.checkout "master", :strategy => :force

      # Update .gitlab-ci.yml and commit
      update_gitlab_ci_yaml(clone, '.gitlab-ci.yml', source_repo_detail.ssh_url, dest_repo.ssh_url_to_repo)

      # Push
      locals = local_branches.keys.map {|name| "refs/heads/#{name}"}
      clone.remotes.each {|r| r.push(locals, :credentials => creds)}

      ## Final Project configuration
      # Enable builds on Gitlab repo, select a runner
      @gitlab.edit_project(dest_repo.id, { builds_enabled: true,
                                           shared_runners_enabled: prompt_bool("Use shared runners?", false) })
      unless (runner_id = prompt_list(@gitlab.runners, "Use specific runner:")).empty?
        @gitlab.enable_project_runner(dest_repo.id, runner_id)
      end

      # Install private key to a secret build variable on gitlab repo
      begin
        @gitlab.create_variable(dest_repo.id, "PUSH_KEY", ssh_key[:privatekey_text])
      rescue Gitlab::Error::BadRequest
        @gitlab.update_variable(dest_repo.id, "PUSH_KEY", ssh_key[:privatekey_text])
      end

      # Create a trigger on GitLab
      trigger = @gitlab.create_trigger(dest_repo.id)
      trigger_uri = URI(@gitlab.endpoint)
      trigger_uri.path = trigger_uri.path + "/projects/#{dest_repo.id}/trigger/builds"
      trigger_uri.query = URI.encode_www_form(token: trigger.token, ref: 'master', 'variables[trigger_source]': 'github' )

      # Install a webhook on GitHub to trigger GitLab
      @github.create_hook(source_repo, 'web',
                          { :url => trigger_uri, :content_type => 'form', :secret => 'gitlabsync' },
                          { :events => ['push'], :active => true })
    }
  end

  # For each branch across all remotes, create the most recent local version
  def sync_remotes_to_local(repo)
    local_branches  = {}
    remote_branches = {}

    repo.branches.each {|branch|
      before, after = branch.name.split('/')
      if after.nil?                 # Test if this is a local branch
        local_branches[before] = branch
      else
        if branch.type == :direct   # Ignore origin/HEAD etc.
          remote_branches[after] = [] unless remote_branches.key? after
          remote_branches[after].push branch
        end
      end
    }

    remote_branches.each {|name, remotes|
      begin
        max = remotes.max {|a, b|
          commit_compare repo, a.target, b.target
        }
      rescue ArgumentError
        raise Exception.new("Could not fast-forward sync #{a.name} with #{b.name}")
      else
        if local_branches.key? name
          if repo.descendant_of? local_branches[name].target, max.target
            max.target = local_branches[name].target
          else
            logged_refupdate(repo, local_branches[name], max)
          end
        else
          puts "Creating branch: #{name} <= #{max.name}"
          local_branches[name] = repo.branches.create(name, max.target.oid)
        end
      end
    }
    local_branches
  end

  private

  def update_gitlab_ci_yaml(repo, file, remote_from, remote_to)
    Dir.chdir(repo.workdir) {
      begin
        ci = File.open(file, 'r:bom|utf-8') {|f| YAML.safe_load f, [], [], true, file}
      rescue
        ci = {}

        # Create the file and add to the index so we may use `git add -e`
        File.write(file, '')
        `git add -N #{file}`
      end

      ci.each {|name, task|
        task['except'] = ['triggers'] + (task['exclude'] || [])
      }
      ci['git-sync'] = {
        'script' => [
          'eval `ssh-agent`',
          'echo "$PUSH_KEY" | ssh-add -',
          "git sync-remote #{remote_from} #{remote_to}",
          'ssh-agent -k'
        ],
        'only' => ['triggers']
      }

      File.write(file, YAML.dump(ci))

      if prompt_bool "Do you want to edit the modified #{file}?"
        `git add -e #{file} > /dev/tty < /dev/tty`
      else
        `git add #{file}`
      end
      `git commit -m ".gitlab-ci.yml: Install git-sync webhook task [AUTO][ci skip]"`
    }
  end

  # Custom <=> comparison for Git commits
  # The greatest commits are leaves, the least commits are parents
  def commit_compare(repo, left, right)
    if left == right
      0
    elsif repo.descendant_of? left, right
      1
    elsif repo.descendant_of? right, left
      -1
    else
      nil
    end
  end

  def logged_refupdate(repo, to, from)
    if to.target != from.target
      puts "Updating branch: #{to.name} <= #{from.name}"
      repo.references.update(to, from.target.oid)
    end
  end

  def gitlab_login
    def gitlab_creds(gitlab, role="master")
      host = URI(gitlab.endpoint).host + "/gitlabsync/#{role}"

      gitlab.private_token =
        if @netrc[host]
          @netrc[host][1]
        else
          input = prompt "Enter the private token for the GitLab user for the role '#{role}': "
          gitlab.private_token = input
          @netrc[host] = user.username, input
          @netrc.save
          input
        end

      user = gitlab.user
      puts "Using user: #{user.name} (#{user.username}) for role #{role}"
    end

    gitlab_creds @gitlab
    gitlab_creds @gitlab_bot, 'syncbot'
  end

  def github_login
    creds = @netrc['api.github.com/gitlabsync'] || @netrc['api.github.com']
    unless creds.nil?
      @github.login, @github.password = creds
    end

    while true
      begin
        # Request current user info to check login successful
        user = @github.user
        if prompt_bool "Use GitHub user #{user.name}?"
          return
        end
      rescue Octokit::Unauthorized => e
        unless @github.login.nil?
          puts e.message
        end

        @github.login = prompt "Enter GitHub username:"
        @github.password = prompt_password "Enter GitHub password:"
      rescue Octokit::OneTimePasswordRequired => e
        otp = prompt "Enter one-time-pass from your #{e.password_delivery}:"
        github_create_token otp
      end
    end
  end

  def github_create_token(otp=nil)
    options = { :scopes => ['repo'], :note => "GitHub-GitLab syncer" }
    if otp
      options[:headers] = { "X-GitHub-OTP" => otp }
    end

    auth = @github.create_authorization options

    @netrc['api.github.com/gitlabsync'] = @github.login, auth.token
    @netrc.save

    # Or access_token, with password cleared
    @github.password = auth.token
  end

  def ssh_keygen(file)
    `ssh-keygen -q -N "" -f #{file}`
    pubkey_path = file + '.pub'
    pubkey_text = File.read(pubkey_path)
    privkey_text = File.read(file)
    { :username => 'git',
      :publickey => pubkey_path, :publickey_text => pubkey_text,
      :privatekey => file, :privatekey_text => privkey_text }
  end

  def prompt(message="Input:", default=nil)
    defaults = if default.nil? then "" else " [#{default}]" end
    puts message + defaults
    result = gets.strip
    if result.empty?
      default
    else
      result
    end
  end

  def prompt_password(message="Password:")
    puts message
    STDIN.noecho(&:gets).strip
  end

  def prompt_bool(message="", default=true)
    defaults = if default then "[Y/n]" else "[y/N]" end
    while true
      print "#{message} #{defaults} "
      result = STDIN.getch
      puts result
      if result.strip.empty? then
        return default
      elsif result =~ /^y/i then
        return true
      elsif result =~ /^n/i then
        return false
      end
    end
  end

  def prompt_list(list, message='Select an item:', field='id')
    puts message
    list.each {|item|
      puts "[#{item.to_h[field]}] #{item}"
    }
    prompt "Selection: "
  end
end

s = Sync.new
s.run

