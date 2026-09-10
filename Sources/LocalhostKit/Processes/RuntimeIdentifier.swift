import Foundation

/// What a process is actually running, read out of its arguments.
///
/// The spike found argv readable for every process we own, and frequently
/// self-describing — Next.js rewrites its own argv to `next-server (v16.2.12)`.
/// A row that says "node · 61587" throws that away; "Next.js 16.2.12" is the
/// thing a developer recognises.
public struct Runtime: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }

    public var description: String {
        version.map { "\(name) \($0)" } ?? name
    }
}

public enum RuntimeIdentifier {
    /// Single tokens that identify a runtime on their own, by executable name.
    private static let byCommand: [String: String] = [
        "next-server": "Next.js", "next": "Next.js",
        "vite": "Vite", "nuxt": "Nuxt", "astro": "Astro", "remix": "Remix",
        "webpack-dev-server": "webpack", "ng": "Angular", "parcel": "Parcel",
        "gunicorn": "Gunicorn", "uvicorn": "Uvicorn", "hypercorn": "Hypercorn",
        "daphne": "Daphne", "flask": "Flask", "celery": "Celery",
        "puma": "Puma", "unicorn": "Unicorn", "rails": "Rails", "thin": "Thin",
        "deno": "Deno", "bun": "Bun", "dotnet": ".NET",
        "caddy": "Caddy", "nginx": "nginx", "httpd": "Apache",
        "postgres": "PostgreSQL", "mysqld": "MySQL", "redis-server": "Redis",
        "mongod": "MongoDB", "memcached": "Memcached", "elasticsearch": "Elasticsearch",
    ]

    /// Runtimes only identifiable from a command plus what follows it.
    private static let byCommandAndArgument: [(command: String, argument: String, name: String)] = [
        ("python", "-m", "Python"),          // refined below by the module name
        ("python3", "-m", "Python"),
        ("webpack", "serve", "webpack"),
        ("cargo", "run", "Cargo"),
        ("go", "run", "Go"),
        ("php", "-S", "PHP"),
        ("rails", "server", "Rails"),
        ("rails", "s", "Rails"),
        ("npm", "run", "npm"),
        ("pnpm", "run", "pnpm"),
        ("yarn", "run", "Yarn"),
    ]

    public static func runtime(arguments: [String]?, executablePath: String?) -> Runtime? {
        guard let arguments, !arguments.isEmpty else { return nil }
        let tokens = arguments.map { ($0 as NSString).lastPathComponent }

        // Next.js and friends rewrite argv[0] to something like
        // "next-server (v16.2.12)", so the version arrives for free.
        if let first = tokens.first {
            let command = first.split(separator: " ").first.map(String.init) ?? first
            if let name = byCommand[command] {
                return Runtime(name: name, version: version(in: first) ?? version(in: arguments))
            }
        }

        for (index, token) in tokens.enumerated() {
            if let name = byCommand[token], index > 0 || tokens.count == 1 {
                return Runtime(name: name, version: version(in: arguments))
            }
            guard index + 1 < tokens.count else { continue }
            let next = tokens[index + 1]
            for entry in byCommandAndArgument where entry.command == token && entry.argument == next {
                // `python -m http.server` is more useful than bare "Python".
                if entry.name == "Python", index + 2 < tokens.count {
                    return Runtime(name: "Python \(tokens[index + 2])", version: nil)
                }
                return Runtime(name: entry.name, version: version(in: arguments))
            }
            // `python manage.py runserver` is Django, not Python.
            if token.hasPrefix("python"), tokens[index...].contains("manage.py") {
                return Runtime(name: "Django", version: nil)
            }
        }

        // Nothing specific matched. Naming the interpreter is still better than
        // nothing, but only when we are sure that is what it is.
        if let first = tokens.first {
            switch first {
            case "node": return Runtime(name: "Node")
            case "python", "python3": return Runtime(name: "Python")
            case "ruby": return Runtime(name: "Ruby")
            case "java": return Runtime(name: "Java")
            default: break
            }
        }
        return nil
    }

    /// Finds `1.2.3` or `v1.2.3`, and refuses anything else — a port or a pid
    /// must never be presented as a version.
    static func version(in text: String) -> String? {
        let pattern = /v?(\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?)/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }

    static func version(in arguments: [String]) -> String? {
        for argument in arguments {
            // Only trust a version that is bracketed or flagged, so that
            // "app:8000" or a file path cannot masquerade as one.
            guard argument.contains("(") || argument.hasPrefix("v") || argument.contains("--version")
            else { continue }
            if let found = version(in: argument) { return found }
        }
        return nil
    }
}
