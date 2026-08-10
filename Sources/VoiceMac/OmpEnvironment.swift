import Foundation

enum OmpEnvironment {
    /// Dirs guaranteed on PATH so the omp launcher can find `bun` even under a minimal
    /// Finder/launchd environment (which omits ~/.bun/bin). Without this, `~/.bun/bin/omp`
    /// (a `#!/bin/sh` that `exec bun ...`) exits 127 and every refine silently falls back.
    static let ensuredPaths = [
        "~/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    private static let preservedNames: Set<String> = [
        "HOME", "PATH", "TMPDIR", "TMP", "TEMP",
        "LANG", "LANGUAGE",
        "BUN_INSTALL",
        "OMP_PROFILE", "PI_PROFILE", "PI_CONFIG_DIR", "PI_CODING_AGENT_DIR",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR",
        "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "GIT_SSL_CAINFO",
    ]

    /// omp refills empty or absent process variables from its dotenv files. A single
    /// whitespace character is truthy to that loader while credential/override
    /// resolution trims it back to absent.
    static let dotenvTombstone = " "

    /// Direct provider credentials, routes, headers, and TLS injection are shadowed
    /// so dotenv files cannot bypass omp's stored OAuth/auth-broker path.
    static let shadowedCredentialNames: Set<String> = [
        "AIAND_API_KEY", "AIMLAPI_API_KEY", "AI_GATEWAY_API_KEY",
        "ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_TOKEN_PLAN_API_KEY",
        "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_SEARCH_API_KEY",
        "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_BASE_URL",
        "AZURE_OPENAI_DEPLOYMENT_NAME_MAP", "AZURE_OPENAI_RESOURCE_NAME",
        "AWS_ACCESS_KEY_ID", "AWS_BEARER_TOKEN_BEDROCK", "AWS_CONFIG_FILE",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_PROFILE", "AWS_ROLE_ARN", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_SHARED_CREDENTIALS_FILE", "AWS_WEB_IDENTITY_TOKEN_FILE",
        "BAILIAN_TOKEN_PLAN_API_KEY", "BASETEN_API_KEY", "BRAVE_API_KEY",
        "CEREBRAS_API_KEY", "CLAUDE_CODE_CLIENT_CERT", "CLAUDE_CODE_CLIENT_KEY",
        "NODE_EXTRA_CA_CERTS",
        "CLOUDFLARE_AI_GATEWAY_API_KEY", "CLOUDSDK_AUTH_ACCESS_TOKEN",
        "COPILOT_GITHUB_TOKEN", "COREWEAVE_API_KEY", "CURSOR_ACCESS_TOKEN",
        "DEEPSEEK_API_KEY", "DEVIN_API_KEY", "FIREPASS_API_KEY", "FIREWORKS_API_KEY",
        "EXA_API_KEY", "FOUNDRY_BASE_URL", "FUGU_API_KEY", "FUGU_BASE_URL",
        "GEMINI_API_KEY", "GITHUB_TOKEN", "GITLAB_TOKEN",
        "GMI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_CLOUD_ACCESS_TOKEN", "GOOGLE_CLOUD_API_KEY", "GH_TOKEN", "GROQ_API_KEY",
        "HF_TOKEN", "HUGGINGFACE_HUB_TOKEN", "JINA_API_KEY", "KAGI_API_KEY",
        "KILO_API_KEY", "KIMI_API_KEY", "KIMI_SEARCH_API_KEY",
        "LITELLM_API_KEY", "LITELLM_BASE_URL", "LLAMA_CPP_API_KEY", "LM_STUDIO_API_KEY",
        "META_API_KEY", "MINIMAX_API_KEY", "MINIMAX_CODE_API_KEY",
        "MINIMAX_CODE_CN_API_KEY", "MISTRAL_API_KEY", "MODEL_API_KEY",
        "MOONSHOT_API_KEY", "MOONSHOT_BASE_URL", "MOONSHOT_SEARCH_API_KEY",
        "NANO_GPT_API_KEY",
        "NOVITA_API_KEY", "NVIDIA_API_KEY", "OLLAMA_API_KEY", "OLLAMA_CLOUD_API_KEY",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_CODEX_OAUTH_TOKEN",
        "OPENCODE_API_KEY",
        "OPENROUTER_API_KEY", "PARALLEL_API_KEY", "PERPLEXITY_API_KEY",
        "PERPLEXITY_COOKIES", "QIANFAN_API_KEY", "QWEN_OAUTH_TOKEN",
        "QWEN_PORTAL_API_KEY", "SAKANA_API_KEY", "SAKANA_BASE_URL",
        "SEARXNG_BASIC_PASSWORD",
        "SEARXNG_BASIC_USERNAME", "SEARXNG_TOKEN", "SILICONFLOW_API_KEY",
        "SILICONFLOW_CN_API_KEY", "SMITHERY_API_KEY", "SYNTHETIC_API_KEY",
        "TAVILY_API_KEY", "TOGETHER_API_KEY", "UMANS_AI_CODING_PLAN_API_KEY",
        "VENICE_API_KEY", "VERCEL_AI_GATEWAY_API_KEY", "VLLM_API_KEY",
        "VOICEOOUR_REFINER_API_KEY", "WAFER_SERVERLESS_API_KEY", "WANDB_API_KEY",
        "XAI_API_KEY", "XAI_BASE_URL", "XAI_OAUTH_TOKEN", "XIAOMI_API_KEY",
        "XIAOMI_TOKEN_PLAN_AMS_API_KEY", "XIAOMI_TOKEN_PLAN_CN_API_KEY",
        "XIAOMI_TOKEN_PLAN_SGP_API_KEY", "ZAI_API_KEY", "ZENMUX_API_KEY", "ZHIPU_API_KEY",
    ]

    /// Returns a minimal child environment with a launch-safe PATH and no inherited
    /// direct-provider credentials. HOME and broker settings remain available so omp
    /// can use its own credential store or a configured auth broker.
    static func augmented(
        _ base: [String: String],
        workingDirectory: URL? = nil
    ) -> [String: String] {
        var env: [String: String] = [:]
        env.reserveCapacity(preservedNames.count + shadowedCredentialNames.count)
        for (key, value) in base {
            guard
                preservedNames.contains(key)
                    || key.hasPrefix("LC_")
                    || key.hasPrefix("XDG_")
                    || key.hasPrefix("OMP_AUTH_BROKER_")
            else { continue }
            env[key] = value
        }
        let home = base["HOME"] ?? NSHomeDirectory()
        let expanded = ensuredPaths.map { path -> String in
            path.hasPrefix("~") ? home + path.dropFirst() : path
        }
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var merged: [String] = []
        for entry in expanded + existing where !entry.isEmpty && seen.insert(entry).inserted {
            merged.append(entry)
        }
        env["HOME"] = home
        env["PATH"] = merged.joined(separator: ":")
        if env["BUN_INSTALL"] == nil { env["BUN_INSTALL"] = home + "/.bun" }
        for name in shadowedCredentialNames {
            env[name] = dotenvTombstone
        }
        for name in dotenvNames(base: base, workingDirectory: workingDirectory)
        where !isPreserved(name) {
            env[name] = dotenvTombstone
        }
        env["CLAUDE_CODE_USE_FOUNDRY"] = "false"
        return env
    }

    private static func isPreserved(_ name: String) -> Bool {
        preservedNames.contains(name)
            || name.hasPrefix("LC_")
            || name.hasPrefix("XDG_")
            || name.hasPrefix("OMP_AUTH_BROKER_")
    }

    private static func dotenvNames(
        base: [String: String],
        workingDirectory: URL?
    ) -> Set<String> {
        let home = base["HOME"] ?? NSHomeDirectory()
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let configuredRoot =
            base["PI_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? ".omp"
        let relativeRoot = configuredRoot.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let baseRoot =
            homeURL
            .appendingPathComponent(relativeRoot, isDirectory: true)
            .standardizedFileURL
        let rawProfile =
            base.keys.contains("OMP_PROFILE")
            ? base["OMP_PROFILE"]
            : base["PI_PROFILE"]
        let profile = rawProfile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let namedProfile = profile.flatMap {
            $0.isEmpty || $0 == "default" ? nil : $0
        }
        let configRoot =
            namedProfile.map {
                baseRoot
                    .appendingPathComponent("profiles", isDirectory: true)
                    .appendingPathComponent($0, isDirectory: true)
            } ?? baseRoot
        let agentDirectory: URL
        if namedProfile == nil,
            let override = base["PI_CODING_AGENT_DIR"],
            !override.isEmpty
        {
            agentDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            agentDirectory = configRoot.appendingPathComponent("agent", isDirectory: true)
        }

        let projectDirectory =
            workingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let urls = [
            projectDirectory.appendingPathComponent(".env"),
            agentDirectory.appendingPathComponent(".env"),
            configRoot.appendingPathComponent(".env"),
            homeURL.appendingPathComponent(".env"),
        ]

        var names = Set<String>()
        var seenPaths = Set<String>()
        for url in urls where seenPaths.insert(url.standardizedFileURL.path).inserted {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let name = dotenvName(in: String(line)) else { continue }
                names.insert(name)
                if name.hasPrefix("OMP_") {
                    names.insert("PI_" + String(name.dropFirst(4)))
                }
            }
        }
        return names
    }

    private static func dotenvName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
            let separator = trimmed.firstIndex(of: "=")
        else {
            return nil
        }
        var name = String(trimmed[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("export") {
            let suffix = name.dropFirst("export".count)
            guard let first = suffix.first, first == " " || first == "\t" else {
                return nil
            }
            name = String(suffix).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard
            name.range(
                of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }
        return name
    }
}
