import Foundation

/// Every word `flightdeck --help` and `flightdeck help VERB` print: a one-paragraph overview,
/// the verbs grouped by what they act on, and one page per verb. Kept apart from the parser so
/// a page can be read (and tested) without parsing anything, and kept as data so the overview's
/// list and the pages can never name different verbs.
public enum CLIHelp {
    /// One verb's page. `name` is the topic as typed after `help` (`send`, `plan approve`).
    struct Page {
        let name: String
        /// One line: what the verb is for. Also the verb's row in the overview.
        let summary: String
        let usage: [String]
        /// What it does, in prose; re-flowed to 80 columns when printed.
        let about: String
        /// Operands and flags, `(term, meaning)`.
        var arguments: [(String, String)] = []
        var options: [(String, String)] = []
        var examples: [String] = []
    }

    /// A verb with subcommands (`plan`, `host`, …): its own page lists them.
    struct Family {
        let name: String
        let summary: String
        let about: String
    }

    struct Section {
        let title: String
        let blurb: String
        let pages: [Page]
    }

    // MARK: - Shared wording

    private static let sessionArg = ("S", "the session (tab): self, its exact title, its full id, or 4+ leading characters of its id")
    private static let projectArg = ("P", "the project: . or here (the project holding this directory), its path, its name, or 4+ leading characters of its id")
    private static let runArg = ("RUN", "a run id as printed by run, up or ps (r and digits, e.g. r7)")
    private static let serviceArg = ("SERVICE", "a service's run id, or the name of the recipe that started it")
    private static let runFlags: [(String, String)] = [
        ("--on H", "the host to run on; defaults to the recipe's host, then the project's default_host"),
        ("--include P", "also send the git-ignored file P (e.g. .env); repeatable. Ignored files are never sent otherwise"),
        ("--fetch G", "copy files matching glob G back from the host when the run ends (e.g. build/**/*.xcresult); repeatable"),
        ("--env K=V", "set an environment variable on the host; repeatable. Your local environment is never sent"),
        ("--pty", "run under a terminal sized to yours, for a command that needs one"),
        ("--screen", "the command needs the host's screen (UI tests); waits if another run holds it"),
        ("--detach", "print the run id and return at once; follow it with wait, logs or stop"),
    ]

    // MARK: - The catalogue

    static let sections: [Section] = [
        Section(
            title: "Sessions",
            blurb: "Watch, drive and manage the agent tabs Flight Deck has open.",
            pages: [
                Page(
                    name: "ls", summary: "list projects and their sessions",
                    usage: ["flightdeck ls [P | --project P]"],
                    about: """
                    Prints every project Flight Deck has open with its sessions: id, title, agent and
                    activity (idle, busy or waiting). A table on a terminal; JSON when piped or
                    with --json.
                    """,
                    arguments: [projectArg],
                    options: [("--project P", "same as giving P; show only that project")],
                    examples: ["flightdeck ls", "flightdeck ls . --json"]
                ),
                Page(
                    name: "tail", summary: "stream fleet events as they happen",
                    usage: ["flightdeck tail [--session S] [--since SEQ] [--no-snapshot]"],
                    about: """
                    Prints the current snapshot, then one JSON line per event until interrupted.
                    Survives a Flight Deck restart: it reconnects and resumes from the last event
                    it printed. A fresh {"type":"snapshot",…} line means the stream was reset.
                    """,
                    options: [
                        ("--session S", "only events for session S (\(sessionArg.1))"),
                        ("--since SEQ", "resume after event number SEQ instead of starting from now"),
                        ("--no-snapshot", "skip the opening snapshot; print events only"),
                    ],
                    examples: ["flightdeck tail --session self | jq .type"]
                ),
                Page(
                    name: "wait", summary: "block until a session reaches a state, or a delegated run ends",
                    usage: [
                        "flightdeck wait S --for idle|busy|waiting|gone [--timeout D]",
                        "flightdeck wait RUN [--timeout D] [--from N]",
                    ],
                    about: """
                    With --for, blocks until session S is idle (its turn ended), busy (working),
                    waiting (asking you something) or gone (closed), then exits 0. It waits as
                    long as it takes unless --timeout is given; on timeout it exits 1 with
                    timed_out. Use send --wait, not send then wait: the tab is still idle when
                    send returns.

                    With a run id (r7) and no --for, streams that delegated run's output until it
                    ends, then exits with the run's own exit status. It gives up after 9 minutes
                    by default with exit 124, which means the run is still going: wait again.
                    """,
                    arguments: [sessionArg, runArg],
                    options: [
                        ("--for STATE", "the session state to wait for: idle, busy, waiting or gone"),
                        ("--timeout D", "give up after D seconds"),
                        ("--from N", "runs only: resume the output at byte offset N instead of replaying it all"),
                    ],
                    examples: ["flightdeck wait \"API refactor\" --for idle --timeout 600", "flightdeck wait r7"]
                ),
                Page(
                    name: "send", summary: "type a message into a session's agent",
                    usage: ["flightdeck send S TEXT [--wait [--timeout D]]"],
                    about: """
                    Types TEXT at session S's prompt and submits it, exactly as if you had typed
                    it. Returns once Flight Deck has accepted the text. With --wait, it then
                    blocks until the turn that text started has ended (idle, or waiting on you)
                    and prints the session.

                    Text that starts with - goes after --, or it is read as a flag.
                    """,
                    arguments: [sessionArg, ("TEXT", "the message; quote it")],
                    options: [
                        ("--wait", "block until the turn this message started has ended"),
                        ("--timeout D", "with --wait: give up after D seconds (exit 1, timed_out)"),
                    ],
                    examples: [
                        "flightdeck send self \"run the tests\"",
                        "flightdeck send cafe1234 --wait --timeout 900 -- \"- fix the lint errors\"",
                    ]
                ),
                Page(
                    name: "peer", summary: "message another agent tab natively",
                    usage: [
                        "flightdeck peer list",
                        "flightdeck peer send TARGET TEXT [--notify-when-idle] [--from TAB]",
                        "flightdeck peer receive [--after CURSOR] [--from TAB]",
                        "flightdeck peer mcp",
                    ],
                    about: """
                    Native cross-agent messaging between Claude and Codex tabs. list shows the
                    tabs that can be reached; send delivers TEXT as a peer message rather than
                    typing it; receive reads this tab's inbox; mcp serves the same verbs over
                    MCP. A send acknowledges the socket write, not that the model read it.
                    Inside a tab the sender is authenticated automatically.
                    """,
                    arguments: [("TARGET", "an exact tab name, tab id, native conversation id, or uds: address"),
                                ("TEXT", "the message; quote it")],
                    options: [
                        ("--notify-when-idle", "send: also report back when the target goes idle"),
                        ("--after CURSOR", "receive: only messages after this inbox cursor"),
                        ("--from TAB", "the sending tab, for a human shell outside any tab"),
                    ],
                    examples: ["flightdeck peer send \"The Plan\" \"U14 done; report in reports/u14.md\""]
                ),
                Page(
                    name: "new", summary: "open a new session in a project",
                    usage: ["flightdeck new P [--agent A [--account N]]"],
                    about: """
                    Opens a new tab in project P with its default agent, or with agent A. See
                    options P for the agents and accounts a project offers. An agent/account that
                    does not exist is refused (exit 2) with the list of ones that do.
                    """,
                    arguments: [projectArg],
                    options: [
                        ("--agent A", "the agent to start (e.g. claude, codex); see flightdeck options P"),
                        ("--account N", "with --agent: that agent's Nth account, from 0 (the default)"),
                    ],
                    examples: ["flightdeck new .", "flightdeck new . --agent codex --account 1"]
                ),
                Page(
                    name: "options", summary: "list the agents and accounts new can open in a project",
                    usage: ["flightdeck options P"],
                    about: """
                    Prints the rows of project P's new-session menu: each agent and account that
                    flightdeck new P --agent A --account N can open.
                    """,
                    arguments: [projectArg]
                ),
                Page(
                    name: "close", summary: "close a session",
                    usage: ["flightdeck close S"],
                    about: """
                    Closes session S's tab, as its close button does. It can be reopened with
                    flightdeck reopen; flightdeck closed lists the ones that can.
                    """,
                    arguments: [sessionArg]
                ),
                Page(
                    name: "reopen", summary: "reopen a closed session",
                    usage: ["flightdeck reopen ID"],
                    about: "Reopens a recently closed session. Find its id with flightdeck closed.",
                    arguments: [("ID", "the closed session's full id (a UUID); titles and prefixes are not accepted")]
                ),
                Page(
                    name: "closed", summary: "list recently closed sessions",
                    usage: ["flightdeck closed"],
                    about: "Lists recently closed sessions, newest first, with the ids flightdeck reopen takes."
                ),
                Page(
                    name: "rename", summary: "retitle a session",
                    usage: ["flightdeck rename S TITLE"],
                    about: "Sets session S's tab title. The new title then names it to every other verb.",
                    arguments: [sessionArg, ("TITLE", "the new title; quote it")],
                    examples: ["flightdeck rename self \"API refactor\""]
                ),
                Page(
                    name: "read", summary: "mark a session as read",
                    usage: ["flightdeck read S"],
                    about: "Clears session S's unread marker in the sidebar and on the phone.",
                    arguments: [sessionArg]
                ),
                Page(
                    name: "unread", summary: "mark a session as unread",
                    usage: ["flightdeck unread S"],
                    about: "Marks session S as unread, so it stands out in the sidebar until opened.",
                    arguments: [sessionArg]
                ),
                Page(
                    name: "collapse", summary: "collapse or expand a project in the sidebar",
                    usage: ["flightdeck collapse P [--off]"],
                    about: "Collapses project P's group in the sidebar, or expands it with --off.",
                    arguments: [projectArg],
                    options: [("--off", "expand the project instead")]
                ),
                Page(
                    name: "search", summary: "search past conversations",
                    usage: ["flightdeck search QUERY [--limit N]"],
                    about: """
                    Searches the transcripts of every agent's past conversations and prints the
                    matches, best first. Open one with flightdeck open.
                    """,
                    arguments: [("QUERY", "the words to look for; quote a phrase")],
                    options: [("--limit N", "at most N matches (default 20)")],
                    examples: ["flightdeck search \"socket timeout\" --limit 5"]
                ),
                Page(
                    name: "open", summary: "open a past conversation in a new tab",
                    usage: ["flightdeck open CONVO --project PATH"],
                    about: "Resumes past conversation CONVO, as found by flightdeck search, in a new tab of the project at PATH.",
                    arguments: [("CONVO", "the conversation id from flightdeck search")],
                    options: [("--project PATH", "required: the project directory to open it in")]
                ),
                Page(
                    name: "timeline", summary: "print a page of a session's transcript",
                    usage: ["flightdeck timeline S [--before N | --after N | --around N] [--limit N]"],
                    about: """
                    Prints a page of session S's transcript: messages, tool calls and their
                    results. With no anchor it prints the latest page; the anchors page backwards
                    and forwards by entry index.
                    """,
                    arguments: [sessionArg],
                    options: [
                        ("--before N", "the entries just before entry N"),
                        ("--after N", "the entries just after entry N"),
                        ("--around N", "the entries centred on entry N"),
                        ("--limit N", "at most N entries (default 40)"),
                    ],
                    examples: ["flightdeck timeline self --limit 10"]
                ),
            ]
        ),
        Section(
            title: "Prompts and plans",
            blurb: "Answer what an agent is asking: permission dialogs, questions and plans waiting for review.",
            pages: [
                Page(
                    name: "prompt", summary: "show what a session is asking",
                    usage: ["flightdeck prompt S"],
                    about: """
                    Prints the permission dialog or question session S has open: its kind, call
                    id, questions and numbered options. Use it to build an answer.
                    """,
                    arguments: [sessionArg]
                ),
                Page(
                    name: "answer", summary: "answer a session's open dialog",
                    usage: ["flightdeck answer S allow|deny|SELECTIONS [--call C]"],
                    about: """
                    Answers the dialog flightdeck prompt S shows. A permission dialog takes allow
                    or deny. A question takes SELECTIONS: a JSON array holding, for each
                    question in order, the array of chosen option numbers (from 0). A sign-in
                    cannot be answered here; finish it on the Mac or phone.
                    """,
                    arguments: [
                        sessionArg,
                        ("allow | deny", "for a permission dialog"),
                        ("SELECTIONS", "for questions, e.g. '[[0,1],[2]]': options 0 and 1 of the first, option 2 of the second"),
                    ],
                    options: [("--call C", "the call id from flightdeck prompt; refuses the answer if a different dialog is now open")],
                    examples: ["flightdeck answer self allow", "flightdeck answer cafe1234 '[[1]]'"]
                ),
                Page(
                    name: "abort", summary: "press Escape at a stuck dialog",
                    usage: ["flightdeck abort S"],
                    about: """
                    Dismisses a dialog Flight Deck cannot identify, which leaves session S waiting
                    with nothing to answer. Only accepted for a session Flight Deck has judged to
                    be stuck that way; use answer for an ordinary dialog.
                    """,
                    arguments: [sessionArg]
                ),
                Page(
                    name: "plan approve", summary: "approve the plan a session is waiting on",
                    usage: ["flightdeck plan approve S [--feedback F]"],
                    about: "Approves the plan session S has open for review, so the agent goes ahead with it.",
                    arguments: [sessionArg],
                    options: [("--feedback F", "notes for the agent to take into account as it goes")]
                ),
                Page(
                    name: "plan reject", summary: "send a plan back for changes",
                    usage: ["flightdeck plan reject S [--feedback F]"],
                    about: "Rejects the plan session S has open for review and asks the agent to revise it.",
                    arguments: [sessionArg],
                    options: [("--feedback F", "what to change")]
                ),
                Page(
                    name: "plan annotate", summary: "comment on an open plan",
                    usage: ["flightdeck plan annotate S TEXT [--block N]"],
                    about: """
                    Adds a comment to the plan session S has open for review, without approving or
                    rejecting it. The comments go to the agent with the eventual verdict.
                    """,
                    arguments: [sessionArg, ("TEXT", "the comment; quote it")],
                    options: [("--block N", "attach it to the plan's Nth block (from 0) rather than to the whole plan")]
                ),
            ]
        ),
        Section(
            title: "Accounts",
            blurb: "Move a conversation to another account or account pool, e.g. when one runs out of usage.",
            pages: [
                Page(
                    name: "account list", summary: "list the accounts a session's agent can move to",
                    usage: ["flightdeck account list [--session S]", "flightdeck account ls [--session S]"],
                    about: "Lists the accounts and pools session S's agent can move to, and which one it is on now.",
                    options: [("--session S", "the session (default: self)")]
                ),
                Page(
                    name: "account switch", summary: "move a conversation to another account or pool",
                    usage: ["flightdeck account switch TARGET [--session S]"],
                    about: """
                    Moves session S's conversation onto TARGET and continues it there. Every word
                    after switch is the target, so a name with spaces needs no quotes.
                    """,
                    arguments: [("TARGET", "an account email, account name or pool name from account list")],
                    options: [("--session S", "the session (default: self)")],
                    examples: ["flightdeck account switch My Work"]
                ),
            ]
        ),
        Section(
            title: "Delegated runs",
            blurb: """
            Run commands on another paired machine (a Mac mini, a Linux box, a cloud machine).
            Your uncommitted tree is synced there, output streams back, files the run changed
            come back as a patch, and the exit status is the remote command's own. A failure
            of delegation itself exits 125 with one flightdeck: line naming the next step.
            """,
            pages: [
                Page(
                    name: "run", summary: "sync this tree to a host and run a command there",
                    usage: [
                        "flightdeck run [--on H] [OPTIONS] -- CMD...",
                        "flightdeck run RECIPE [OPTIONS] [-- EXTRA_ARGS...]",
                    ],
                    about: """
                    Sends your working tree, uncommitted changes included, to a host, runs CMD (or
                    the recipe RECIPE from .flightdeck/delegate.toml) there, streams its output and
                    exits with its exit status. Files the command changed come back as a patch:
                    read it with flightdeck diff RUN, take it with flightdeck apply RUN. Ctrl-C is
                    forwarded to the host. A recipe marked long, or --detach, returns a run id at
                    once instead.
                    """,
                    arguments: [
                        ("RECIPE", "a recipe name; see flightdeck recipe ls"),
                        ("CMD...", "the command and its arguments, after --"),
                    ],
                    options: runFlags,
                    examples: [
                        "flightdeck run --on mini -- xcodebuild test -scheme App",
                        "flightdeck run ui-tests --fetch 'build/**/*.xcresult'",
                    ]
                ),
                Page(
                    name: "exec", summary: "run a command in a host's checkout without syncing",
                    usage: ["flightdeck exec --on H [OPTIONS] -- CMD..."],
                    about: """
                    Runs CMD in the host's existing checkout of this project without sending
                    anything first. For looking around: ls, git status, xcrun simctl list.
                    """,
                    arguments: [("CMD...", "the command and its arguments, after --")],
                    options: runFlags.filter { $0.0 != "--include P" && $0.0 != "--fetch G" }
                ),
                Page(
                    name: "up", summary: "start a background service on a host",
                    usage: [
                        "flightdeck up RECIPE [OPTIONS]",
                        "flightdeck up --on H --port L:R... [OPTIONS] -- CMD...",
                    ],
                    about: """
                    Syncs this tree and starts a long-lived service (a database, a dev server) on
                    a host, forwarding its ports to 127.0.0.1 here. Prints the service's run id
                    and returns. It stops when this tab closes, or with flightdeck down.
                    """,
                    arguments: [
                        ("RECIPE", "a service recipe; see flightdeck recipe ls"),
                        ("CMD...", "the command and its arguments, after --"),
                    ],
                    options: [("--port L:R", "forward local port L to the host's port R; repeatable. Also 5432 (same both ends) and auto:5432 (any free local port)")]
                        + runFlags.filter { $0.0 != "--detach" },
                    examples: ["flightdeck up --on linux --port 5432 -- docker compose up db"]
                ),
                Page(
                    name: "down", summary: "stop a service",
                    usage: ["flightdeck down SERVICE"],
                    about: "Stops a service started with up, then runs its recipe's down command if it has one.",
                    arguments: [serviceArg]
                ),
                Page(
                    name: "restart", summary: "restart a service",
                    usage: ["flightdeck restart SERVICE"],
                    about: "Stops a service started with up and starts it again with the same command and ports.",
                    arguments: [serviceArg]
                ),
                Page(
                    name: "sync", summary: "push this tree into a running service's checkout",
                    usage: ["flightdeck sync SERVICE"],
                    about: """
                    Sends your current tree to a running service's checkout in place, without
                    restarting it (unless its recipe sets restart_on_sync).
                    """,
                    arguments: [serviceArg]
                ),
                Page(
                    name: "ps", summary: "list this session's runs and services",
                    usage: ["flightdeck ps"],
                    about: "Lists the delegated runs and services this session started: id, host, kind, state, command and forwarded ports."
                ),
                Page(
                    name: "logs", summary: "replay a run's output",
                    usage: ["flightdeck logs RUN [--follow] [--from N]"],
                    about: "Prints the output a run has written so far (up to 64 MiB; older output is dropped first).",
                    arguments: [runArg],
                    options: [
                        ("--follow, -f", "keep printing new output until the run ends"),
                        ("--from N", "start at byte offset N"),
                    ]
                ),
                Page(
                    name: "stop", summary: "cancel a run",
                    usage: ["flightdeck stop RUN"],
                    about: "Cancels a delegated run on its host.",
                    arguments: [runArg]
                ),
                Page(
                    name: "diff", summary: "show the files a run changed",
                    usage: ["flightdeck diff RUN"],
                    about: "Prints the patch of files RUN changed on the host. A patch over 1 MiB is written to a file and its path printed.",
                    arguments: [runArg]
                ),
                Page(
                    name: "apply", summary: "apply a run's changes to this tree",
                    usage: ["flightdeck apply RUN"],
                    about: """
                    Merges the patch of files RUN changed into your current tree. Where your tree
                    has moved on it leaves conflict markers rather than overwriting.
                    """,
                    arguments: [runArg]
                ),
            ]
        ),
        Section(
            title: "Recipes",
            blurb: "Named, reusable commands for delegated runs, kept in .flightdeck/delegate.toml (commit it).",
            pages: [
                Page(
                    name: "recipe ls", summary: "list this project's recipes and routes",
                    usage: ["flightdeck recipe ls"],
                    about: "Lists the recipes and routes in this project's .flightdeck/delegate.toml, with the default host and include list."
                ),
                Page(
                    name: "recipe check", summary: "validate .flightdeck/delegate.toml",
                    usage: ["flightdeck recipe check"],
                    about: "Checks this project's .flightdeck/delegate.toml and names each problem. Run it after editing the file by hand."
                ),
                Page(
                    name: "recipe add", summary: "save a command as a recipe",
                    usage: ["flightdeck recipe add NAME --run CMD [OPTIONS]"],
                    about: "Adds recipe NAME to this project's .flightdeck/delegate.toml, creating the file if needed.",
                    arguments: [("NAME", "the recipe's name, as run RECIPE and up RECIPE take it")],
                    options: [
                        ("--run CMD", "required: the command, as one quoted string"),
                        ("--host H", "the host it runs on when --on is not given"),
                        ("--service", "a long-lived service, started with up rather than run"),
                        ("--down CMD", "a service's shutdown command, run after it is stopped (e.g. docker compose down)"),
                        ("--restart-on-sync", "a service restarts after each flightdeck sync"),
                        ("--long", "run returns the run id at once, as with --detach"),
                        ("--screen", "needs the host's screen (UI tests)"),
                        ("--port L:R", "a port to forward; repeatable"),
                        ("--fetch G", "a glob of files to copy back; repeatable"),
                        ("--env K=V", "a variable set on the host; repeatable"),
                        ("--apply review|auto", "review (default): wait for flightdeck apply; auto: apply changes as soon as the run ends"),
                        ("--pool N", "how many checkouts of this worktree the host keeps (default 2), so that many runs can go at once"),
                    ],
                    examples: ["flightdeck recipe add ui-tests --run 'xcodebuild test -scheme AppUITests' --host mini --screen --long"]
                ),
            ]
        ),
        Section(
            title: "Hosts",
            blurb: "The machines paired with Flight Deck that delegated runs go to.",
            pages: [
                Page(
                    name: "host ls", summary: "list paired hosts",
                    usage: ["flightdeck host ls [--disk [HOST]]"],
                    about: "Lists the paired hosts and whether each is online.",
                    options: [("--disk [HOST]", "instead, show the disk each project's checkouts use, on HOST or on every host")]
                ),
                Page(
                    name: "host info", summary: "describe a host",
                    usage: ["flightdeck host info HOST"],
                    about: "Shows HOST's platform, Xcode and simulators, Docker, free disk and whether its screen is free.",
                    arguments: [("HOST", "a host name from flightdeck host ls")]
                ),
                Page(
                    name: "host prune", summary: "delete a host's checkouts",
                    usage: ["flightdeck host prune HOST [--repo R]"],
                    about: "Deletes the checkouts on HOST, and their build output with them, to free disk. The next run recreates what it needs.",
                    arguments: [("HOST", "a host name from flightdeck host ls")],
                    options: [("--repo R", "only this repository's checkouts")]
                ),
            ]
        ),
        Section(
            title: "Cloud machines",
            blurb: """
            Hosts Flight Deck creates in your own AWS or GCP account from an [infra.NAME] table
            in .flightdeck/delegate.toml. They cost money by the hour; each is destroyed at its
            ttl, or when idle. Failures exit 125, with one flightdeck: line per problem.
            """,
            pages: [
                Page(
                    name: "infra up", summary: "create a cloud machine",
                    usage: ["flightdeck infra up NAME"],
                    about: """
                    Creates the machine described by [infra.NAME] in this repo's
                    .flightdeck/delegate.toml and pairs it as a host. Takes minutes. Ctrl-C stops
                    watching, not the create: it carries on in Flight Deck.
                    """,
                    arguments: [("NAME", "the infra table's name")]
                ),
                Page(
                    name: "infra down", summary: "destroy a cloud machine",
                    usage: ["flightdeck infra down NAME", "flightdeck infra down --orphan KIND:ID"],
                    about: "Destroys machine NAME and everything created with it, or one leftover resource found by infra ls --orphans.",
                    arguments: [("NAME", "the machine's name")],
                    options: [("--orphan KIND:ID", "destroy this leftover resource instead")]
                ),
                Page(
                    name: "infra ls", summary: "list cloud machines and their cost",
                    usage: ["flightdeck infra ls [--orphans]"],
                    about: "Lists the cloud machines with their state, hourly rate, spend so far and time left before ttl.",
                    options: [("--orphans", "instead, list resources left behind that no machine owns")]
                ),
                Page(
                    name: "infra doctor", summary: "check cloud tools and accounts",
                    usage: ["flightdeck infra doctor"],
                    about: "Checks the tools (OpenTofu, cloud CLIs) and the credentials cloud machines need, and names the fix for each problem."
                ),
                Page(
                    name: "infra extend", summary: "keep a cloud machine longer",
                    usage: ["flightdeck infra extend NAME DURATION"],
                    about: "Pushes machine NAME's ttl back by DURATION. It keeps costing money for that long.",
                    arguments: [("NAME", "the machine's name"), ("DURATION", "e.g. 30m, 1h or 1h30m")]
                ),
                Page(
                    name: "infra budget", summary: "this session's cloud budget",
                    usage: ["flightdeck infra budget [show]", "flightdeck infra budget [set] USD",
                            "flightdeck infra budget renew [USD]", "flightdeck infra budget clear"],
                    about: """
                    Shows or changes the cloud budget of the Flight Deck session this runs in (/budget
                    in Claude Code). It counts only the machines this session created. Once they have
                    spent it, they are destroyed and no new one starts. set keeps the spend so far;
                    renew starts again from zero now.
                    """,
                    arguments: [("USD", "dollars, e.g. 20 or $7.50")]
                ),
            ]
        ),
        Section(
            title: "Visual providers",
            blurb: "Providers draw the visuals in Flight Control planning. A provider is a folder with a provider.toml.",
            pages: [
                Page(
                    name: "provider check", summary: "validate a visual provider's folder",
                    usage: ["flightdeck provider check DIR [--run-samples]"],
                    about: """
                    Reads DIR/provider.toml and reports every problem with its line number: the \
                    contract version, the kinds, and whether each kind's entry, instructions and \
                    assets exist inside the folder. A provider is valid whole or not at all.

                    A generator never runs unless you pass --run-samples. Then, for each kind \
                    that has input in DIR/samples/KIND/, it prints the exact command, runs it \
                    in the sandbox (no network, writes only to a private folder) on a private \
                    copy of the folder, and reports the result. Without the flag the last line \
                    says the generator was not run. This works on this Mac only, with Flight \
                    Deck closed.

                    Exit status: 0 valid (warnings may print) · 1 problems found, or a sample \
                    failed · 2 usage error.
                    """,
                    arguments: [("DIR", "the provider's folder, the one holding provider.toml")],
                    options: [("--run-samples", "run the generator on samples/KIND/ in the sandbox")],
                    examples: ["flightdeck provider check .flightdeck/visual-providers/my-charts"]
                ),
            ]
        ),
        Section(
            title: "Plumbing",
            blurb: "For Flight Deck itself and for scripts that need an operation with no verb yet.",
            pages: [
                Page(
                    name: "intake run", summary: "run an intake's planning rounds (Flight Deck only)",
                    usage: ["flightdeck intake run ID --root DIR"],
                    about: "The detached runner Flight Deck launches for a Flight Control intake. Not for running by hand.",
                    arguments: [("ID", "the intake's full id")],
                    options: [("--root DIR", "required: the intake's directory")]
                ),
                Page(
                    name: "raw", summary: "send one protocol frame and print the replies",
                    usage: ["flightdeck raw FRAME"],
                    about: "Sends one client frame to Flight Deck and prints every reply to it. Covers any operation that has no verb yet.",
                    arguments: [("FRAME", "a ClientFrame, as JSON")]
                ),
            ]
        ),
    ]

    static let families: [Family] = [
        Family(name: "plan", summary: "review the plan a session is waiting on",
               about: "Approve, reject or comment on a plan an agent has opened for review."),
        Family(name: "account", summary: "move a conversation to another account",
               about: "List the accounts a session's agent can use, and move its conversation to one."),
        Family(name: "recipe", summary: "manage this project's delegation recipes",
               about: "Recipes are named commands for run and up, kept in .flightdeck/delegate.toml."),
        Family(name: "host", summary: "inspect paired hosts",
               about: "The machines paired with Flight Deck that delegated runs go to."),
        Family(name: "infra", summary: "create and destroy cloud machines",
               about: "Cloud hosts created in your own AWS or GCP account. They cost money by the hour."),
        Family(name: "provider", summary: "check a visual provider",
               about: "Visual providers draw the visuals Flight Control planning shows. Check one before you use it."),
        Family(name: "intake", summary: "Flight Control intake runner",
               about: "Used by Flight Deck itself."),
    ]

    static var pages: [Page] { sections.flatMap(\.pages) }

    // MARK: - Topics

    /// The help topic `words` name: the longest run of leading words that is a page or a family
    /// (`plan approve S` → `plan approve`, `plan` → `plan`). Nil when the first word names
    /// nothing, so the caller can refuse it as an unknown command.
    public static func topic(for words: [String]) -> String? {
        for count in stride(from: min(words.count, 2), through: 1, by: -1) {
            let candidate = words.prefix(count).joined(separator: " ")
            if candidate == "account ls" { return "account list" }
            if pages.contains(where: { $0.name == candidate }) || families.contains(where: { $0.name == candidate }) {
                return candidate
            }
        }
        return nil
    }

    /// The page for `topic`, or the overview when nil.
    public static func text(for topic: String?) -> String {
        guard let topic else { return overview }
        if let page = pages.first(where: { $0.name == topic }) { return render(page) }
        if let family = families.first(where: { $0.name == topic }) { return render(family) }
        return overview
    }

    /// What a usage error prints under its message: the verb's usage lines when the command
    /// line names one, then where to read more.
    public static func hint(for args: [String]) -> [String] {
        let words = args.filter { !$0.hasPrefix("-") }
        guard let topic = topic(for: words) else {
            return ["Run flightdeck --help to see every command."]
        }
        let usage = pages.first(where: { $0.name == topic })?.usage
            ?? pages.filter { $0.name.hasPrefix(topic + " ") }.flatMap(\.usage)
        return ["usage:"] + usage.map { "  " + $0 } + ["Run flightdeck help \(topic) for details."]
    }

    // MARK: - Rendering

    static var overview: String {
        var lines = [
            "flightdeck — drive Flight Deck from the command line",
            "",
            wrap("""
            flightdeck talks to the running Flight Deck app over its local control socket. It \
            does what the app and the phone do: list and watch your agent sessions, type into \
            them, answer their questions and plans, open and close tabs, and search past \
            conversations. It also hands commands to other paired machines (delegated runs, \
            services, cloud machines). Inside a Flight Deck tab, self names that tab, so an \
            agent can use flightdeck on itself or orchestrate others.
            """, indent: ""),
            "",
            "Usage:",
            "  flightdeck COMMAND [ARGUMENTS] [--json] [--socket PATH]",
            "  flightdeck help COMMAND           (or flightdeck COMMAND --help)",
        ]
        let width = pages.map(\.name.count).max() ?? 0
        for section in sections {
            lines += ["", section.title + ":"]
            lines += wrap(section.blurb, indent: "  ").components(separatedBy: "\n")
            lines.append("")
            for page in section.pages {
                lines.append("    " + page.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + page.summary)
            }
        }
        lines += [
            "",
            "Naming things:",
            "  S, a session   self (this tab), its exact title, its full id, or 4+ leading",
            "                 characters of its id. An ambiguous name lists the candidates.",
            "  P, a project   . or here (the project holding this directory), its path, its",
            "                 name, or 4+ leading characters of its id.",
            "",
            "Global options (anywhere before --):",
            "  --json         print JSON (also the default when output is not a terminal)",
            "  --socket PATH  the control socket; default $FLIGHT_DECK_CONTROL_SOCKET, then",
            "                 ~/Library/Application Support/Flight Deck/control.sock",
            "  --help, -h     help for the command it follows",
            "",
            "Flags go before or after operands. Text that starts with - goes after --:",
            "  flightdeck send S --wait -- \"- text\"",
            "",
            "Exit status:",
            "  0 ok · 1 refused by Flight Deck (the reason on stderr) · 2 usage error",
            "  69 Flight Deck is not reachable · 77 this agent's sandbox blocked the socket",
            "  Delegated runs: the remote command's own status; 124 wait timed out (still",
            "  running); 125 delegation itself failed.",
        ]
        return lines.joined(separator: "\n")
    }

    static func render(_ page: Page) -> String {
        var lines = ["flightdeck \(page.name) — \(page.summary)", "", "Usage:"]
        lines += page.usage.map { "  " + $0 }
        lines += ["", wrap(page.about, indent: "")]
        lines += table("Arguments", page.arguments)
        lines += table("Options", page.options)
        if !page.examples.isEmpty {
            lines += ["", "Examples:"] + page.examples.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    static func render(_ family: Family) -> String {
        let subs = pages.filter { $0.name.hasPrefix(family.name + " ") }
        let width = subs.map(\.name.count).max() ?? 0
        var lines = ["flightdeck \(family.name) — \(family.summary)", "", wrap(family.about, indent: ""), "", "Commands:"]
        lines += subs.map { "  " + $0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.summary }
        lines += ["", "Run flightdeck help \(family.name) SUBCOMMAND for details."]
        return lines.joined(separator: "\n")
    }

    /// `Title:` and one row per entry, the meaning wrapped beside its term (or under it,
    /// when the term is too long to share the line).
    private static func table(_ title: String, _ rows: [(String, String)]) -> [String] {
        guard !rows.isEmpty else { return [] }
        let column = min((rows.map(\.0.count).max() ?? 0) + 4, 24)
        var lines = ["", title + ":"]
        for (term, meaning) in rows {
            let pad = String(repeating: " ", count: column)
            let body = wrap(meaning, indent: pad).components(separatedBy: "\n")
            let lead = "  " + term
            if lead.count < column {
                lines.append(lead.padding(toLength: column, withPad: " ", startingAt: 0) + body[0].dropFirst(column))
            } else {
                lines.append(lead)
                lines.append(body[0])
            }
            lines += body.dropFirst()
        }
        return lines
    }

    /// Re-flows `text` to 80 columns, each line led by `indent`. A blank line in `text` starts
    /// a new paragraph.
    static func wrap(_ text: String, indent: String, width: Int = 80) -> String {
        let paragraphs = text.components(separatedBy: "\n\n").map {
            $0.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return paragraphs.map { words in
            var lines: [String] = []
            var line = indent
            for word in words {
                if line.count > indent.count, line.count + 1 + word.count > width {
                    lines.append(line)
                    line = indent
                }
                line += (line.count > indent.count ? " " : "") + word
            }
            lines.append(line)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
