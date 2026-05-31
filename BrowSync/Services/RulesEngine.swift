// RulesEngine.swift
// BrowSync — URL routing rule matcher

import Foundation
import os.log

final class RulesEngine {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "RulesEngine")
    var rules: [BrowserRule] = []
    var defaultBrowser: Browser = .safari

    // MARK: - Match

    /// Returns the target browser for the given URL and optional source app bundle ID.
    /// Rules are evaluated top-down; the first match wins.
    func match(url: URL, sourceApp: String? = nil) -> Browser {
        let host = url.host ?? ""
        let fullURL = url.absoluteString
        let now = Date()

        for rule in rules where rule.enabled {
            // Check time range constraint
            if let timeRange = rule.timeRange, !timeRange.isActive(at: now) {
                continue
            }

            // Check source app constraint (if rule specifies apps, source must be one of them)
            if !rule.sourceApps.isEmpty {
                guard let src = sourceApp, rule.sourceApps.contains(src) else {
                    continue
                }
            }

            // Check domain patterns
            let domainMatched = rule.domains.isEmpty || rule.domains.contains { pattern in
                matchDomain(host: host, pattern: pattern)
            }

            // Check URL patterns
            let urlPatternMatched = rule.urlPatterns.isEmpty || rule.urlPatterns.contains { pattern in
                fullURL.contains(pattern)
            }

            // Both domain + URL pattern must match if both are specified
            // If only one is specified, that one must match
            let domainRequired = !rule.domains.isEmpty
            let urlRequired = !rule.urlPatterns.isEmpty

            if domainRequired && urlRequired {
                if domainMatched && urlPatternMatched {
                    logger.debug("Rule '\(rule.name)' matched → \(rule.targetBrowser.rawValue)")
                    return rule.targetBrowser
                }
            } else if domainRequired {
                if domainMatched {
                    logger.debug("Rule '\(rule.name)' matched (domain) → \(rule.targetBrowser.rawValue)")
                    return rule.targetBrowser
                }
            } else if urlRequired {
                if urlPatternMatched {
                    logger.debug("Rule '\(rule.name)' matched (URL pattern) → \(rule.targetBrowser.rawValue)")
                    return rule.targetBrowser
                }
            } else if !rule.sourceApps.isEmpty {
                // Source-app-only rule already passed the sourceApp check above
                logger.debug("Rule '\(rule.name)' matched (source app) → \(rule.targetBrowser.rawValue)")
                return rule.targetBrowser
            }
        }

        logger.debug("No rule matched, using default: \(self.defaultBrowser.rawValue)")
        return defaultBrowser
    }

    // MARK: - Domain Matching

    /// Supports exact match and wildcard prefix (*.example.com)
    private func matchDomain(host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2)) // remove "*."
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return host == pattern || host == "www." + pattern
    }
}
