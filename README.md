# Pipelines

Pipelines is a macOS menubar app that shows the GitLab pipelines of your merge requests (MRs). It lists the MRs that you wrote, the MRs where you are a reviewer, and the MRs and branches that you add by hand. It sends a notification when a pipeline passes, fails, or stops on manual jobs. You can open a pipeline to see its stages and jobs, retry a failed job, and run a manual job.

The app gets all its data through the `glab` command line tool, so it uses your glab login and stores no token. It works with gitlab.com only.

## Requirements

You need these items before you start:

- macOS 14 or later.
- The Xcode command line tools. You do not need Xcode.
- glab, the GitLab command line tool, logged in to gitlab.com.

## Setup

1. Install the command line tools. If they are already installed, the command tells you so.

```bash
xcode-select --install
```

2. Install glab with Homebrew, and log in to gitlab.com.

```bash
brew install glab
glab auth login
```

3. Make sure that glab is logged in. The command prints "Logged in to gitlab.com as" and your username.

```bash
glab auth status
```

4. Clone this repository and go to its folder.

5. Build and install the app.

```bash
scripts/bundle.sh
```

   The script builds the app, installs it to `/Applications/Pipelines.app`, and starts it.

## Use

The menubar icon shows the worst state among your own MRs and the MRs and branches that you watch. A red cross means a pipeline failed. An orange pause means a pipeline waits on manual jobs. A blue circle means a pipeline is running. A green check means that every pipeline passed. MRs where you are a reviewer and hidden items do not change the icon.

Click the icon to open the panel:

- Click a row to see the stages of its pipeline. Click a stage to see its jobs.
- Under each title, a row shows the repo name and the pipeline state. A branch row also shows who started the pipeline.
- Click Retry next to a failed job to run it again. Click Retry failed jobs to retry all failed jobs of the pipeline.
- Click Run next to a manual job to start it. The job starts at once, with no confirmation. Take care with the jobs in the `maintenance` stage.
- Click the gear icon, then Watch…, to follow an MR or a branch. Paste an MR URL, a branch URL such as `…/-/tree/main`, or a pipeline URL, then press Return. A branch watch shows the latest pipeline on that branch, whoever started it. A pipeline URL watches the branch of that pipeline.
- Right-click a row to pin it, hide it, open it in the browser, or remove a watch. Pinned items move to a Pinned group at the top of the panel. A hidden item sends no notifications. Click the gear icon, then Show Hidden, to see hidden items in a gray group at the bottom.
- Each group lists the item with the newest commit first.

Pipelines checks GitLab every 10 seconds while a pipeline runs, and every 30 seconds when nothing runs. Notifications go out for these events:

| Item | Passed | Failed | Waiting on manual jobs |
|---|---|---|---|
| An MR you wrote | Yes | Yes | Yes |
| An MR you watch | Yes | Yes | Yes |
| A branch you watch | Yes | Yes | Yes |
| An MR you review | Yes | No | Yes |
| A hidden item | No | No | No |

## Update

To update the app, get the latest changes and run the build script again.

```bash
git pull
scripts/bundle.sh
```

The script quits the running app, replaces the copy in Applications, and starts the new one. The login item stays on.

## Troubleshooting

If the panel says "Run glab auth login", your glab login expired or is not valid. Run `glab auth login` again, then click the gear icon and Refresh.

If the panel says that glab was not found, the app looked in `/opt/homebrew/bin`, `/usr/local/bin`, and your login shell. Install glab with Homebrew, then quit Pipelines and open it again.

If no notifications arrive, open System Settings, then Notifications, then Pipelines, and allow notifications.

If the build fails with "plugin for module 'TestingMacros' not found", you ran `swift test` directly. Use `scripts/test.sh` instead.

The build prints lines that start with `ld: warning: search path`. These lines are normal with the command line tools, and you can ignore them.

## Development

The code has two parts. `Sources/PipelineCore` holds the models, the GraphQL queries, the notification rules, the poller, and the glab transport. It has no UI code. `Sources/Pipelines` holds the SwiftUI menubar app.

Run the tests with this command:

```bash
scripts/test.sh
```

`swift run` and the Run button in Xcode start the app with no notifications, because notifications need an app bundle. To test notifications, use `scripts/bundle.sh`.

To publish a signed release that updates itself, follow `docs/RELEASING.md`.

## License

Pipelines is released under the MIT License. See `LICENSE`. The app includes [Sparkle](https://github.com/sparkle-project/Sparkle), which has its own MIT License.
