General Setup
=============
* Get GitLab admin user details
* Get GitLab sync user details
* Get GitHub admin user details

GitHub (<)-> GitLab Sync Setup
==============================
1. Select source GitHub repo
2. Either: Select/create destination GitLab repo
3. Generate a ssh keypair.
4. Install public key to GitHub repo as Deployment Key (with write permissions for reverse sync)
5. Install public key to GitLab sync user.
6. Grant GitLab sync user Developer permissions to 2.
10. Clone 1. add remote 2.
11. Check branches on 1,2 are consistent/fast-forwardable (or 2 is empty), and sync
12. Check out synced master.
13. Update .gitlab-ci.yml with git sync CI task
14. Commit and push all repo branches to both.
7. Enable builds on 2. select a builder.
8. Install private key to secret build variable on 2.
9. Create a trigger on 2.
15. Install webhook for trigger on 1. (with GitHub trigger source variable)

Intended Flows
==============
GitHub -> GitLab
----------------
1. Push to GitHub
2. GitHub webhook calls out to GitLab build trigger
3. GitLab spawns build tasks including/not-excluding the "triggers" pattern.
4. Git sync task executes (in GitHub mode).
5. GitLab version of repository at some unspecified revision/branch is checked out automatically.
6. Spawn ssh-agent with the stored private key.
7. Add GitHub remote and fetch.
8. Fast-forward each GitHub branch into the corresponding GitLab branch, creating if required.
9. If any changes made, push to GitLab. (This build task ends).
10. GitLab receives push and starts standard build process.
11. GitLab executes GitLab->GitHub sync task as part of the standard build, it should be idempotent.

GitLab -> GitHub
----------------
1. Push to GitLab
2. GitLab spawns build tasks.
4. Git sync task executes (in GitLab mode).
5. GitLab version of repository at some current revision/branch is checked out automatically.
6. Spawn ssh-agent with the stored private key.
7. Add GitHub remote and fetch.
8. Fast-forward each GitLab branch into the corresponding GitHub branch, creating if required.
9. If any changes made, push to GitHub. (This build task ends).
10. GitHub receives push, triggers GitLab webhook, the resulting push should be idempotent.

Limitations
===========
* Force pushes on any repo will break the sync, good motivation to forbid them.
* All normal build tasks will need to be marked as excluding triggers, ones that need to be triggered need special
  handling, with build variables to select correct mode.

Notes
=====
* GitLab has undocumented support for Cloning repositories over SSH using an oauth2 token. Use username oauth2 and the
  token as the password. (See https://gitlab.com/gitlab-org/gitlab-ee/commit/54f6d8c7b5a1c67a222011c35ad70909da0e686d)
* GitHub has the ability to clone/push using OAuth2 tokens if the "repo" scope is provided.
