# easy-git setup

One line gets your Mac or Linux computer ready to save and share work on GitHub through
Claude Code.

1. Accept the email invitation to the Zipsense organization on GitHub.
2. Open the **Terminal** app, paste this line, and press Enter:

   ```
   curl -fsSL https://raw.githubusercontent.com/Zipsense/easy-git-setup/main/bootstrap.sh | sh -s -- --orgs Zipsense --plugin Zipsense/team-plugins --with-claude
   ```

3. Follow what it says. Usually you'll press Enter, paste a short code into the GitHub page
   that opens, and click **Authorize**. On a new Mac, an Apple window may ask you to click
   **Install**.

When you see ✅ **All set**, open Claude Code and say **"help"** to see what you can do.

## What it does

It checks each of these and skips whatever is already done:

- installs Git and GitHub's official tool (`gh`), if missing, into your home folder, with no
  admin password;
- logs you in to GitHub (GitHub's own tool stores the login; this script never sees it);
- fills in your name and email for saves, only if they're empty;
- checks you're in the organization;
- installs Claude Code if it's missing;
- adds the **easy-git** plugin to Claude Code and keeps it updated.

It's safe to run again any time. This copy is published from the team's private plugin repo.
