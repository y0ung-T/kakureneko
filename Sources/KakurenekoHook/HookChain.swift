import Darwin

/// `--chain -- <argv…>`: runs the user's previous command (Codex `notify`, Aider `notifications-command`)
/// detached — `posix_spawnp`, stdio `/dev/null`, a new session, no inherited descriptors, default signal
/// dispositions — and never waits for it.
enum HookChain {
    static func spawnDetached(_ argv: [String]) -> Bool {
        guard let program = argv.first, !program.isEmpty else { return false }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else { return false }
        // The hook ignores SIGPIPE and arms SIGALRM: the chained command must start with default dispositions
        // and an empty signal mask.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        sigaddset(&defaults, SIGALRM)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArguments.append(nil)
        defer { for pointer in cArguments { free(pointer) } }

        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, program, &actions, &attributes, cArguments, environ)
        if rc != 0 { errno = rc }
        return rc == 0
    }
}
