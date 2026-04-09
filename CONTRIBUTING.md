Good commit standards for open-source repositories focus on readability, consistency, and enabling automated tools to generate changelogs or manage versioning.
This repo leverages Conventional Commits, which mandates a structured format for commit messages.

# Core Commit Standards

    * Structure: Follow the Conventional Commits format: <type>(<scope>): <description>.
    * Atomic Commits: Each commit should represent one, and only one, logical change (e.g., one feature, one bug fix, or one refactoring).
    * Imperative Mood: Use the imperative, present tense ("add" not "added" or "adds").
    * Concise Subject: Keep the first line to 50–72 characters.
    * Detailed Body: Use the body to explain "why" a change was made and the context, rather than "how" (which the code diff shows).

# Conventional Commits Types
The most widely recommended types for open-source are:

    * feat: A new feature.
    * fix: A bug fix.
    * docs: Documentation changes.
    * style: Formatting, missing semicolons, etc. (no code changes).
    * refactor: Code restructuring that neither fixes a bug nor adds a feature.
    * perf: Performance improvements.
    * test: Adding or updating tests.
    * chore: Maintenance tasks (e.g., dependency updates).

# Best Practices

    * Reference Issues/PRs: Always include the issue or pull request number in the body or footer (e.g., Closes #123).
    * Separate Subject and Body: Use a blank line between the title and the detailed description.
    * Capitalization & Punctuation: Capitalize the subject line but do not end it with a period.
    * Use Squash on Merge: When merging pull requests, prefer "squashing" many small commits into one clean, meaningful commit. Exceptions can be made to preserve information.
    * Sign Commits: sign off commits (with -s flag for local repo user). Given the demonstration nature of this repository, GPG signing is not required (but you do you).
    * Once released, typical length (<200 lines) and atomic scope standards for changes would be applied with PRs.

# Caveats to Best Practices
    * Given the small scope and timeline of the project, atomicity and PR requirements have been relaxed prior to 1.0 to allow for rapid readiness.

# Example of a Good Commit Message
    feat(auth): add password validation to signup form

    Add regex check to ensure passwords are at least 8 characters
    and contain a special character. This improves security based on
    security audit feedback.

    Closes #452

# Automation Tools
    * conventional-pre-commit: Enforces Conventional Commits subject format at commit time.
    * gitlint: Enforces Signed-off-by in the commit body at commit time.
