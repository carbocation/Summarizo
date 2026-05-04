import Foundation

enum PrimaryPDFSelector {
    private static let ambiguityScoreDelta = 20

    static func selectPrimaryPDFs(from candidates: [ZoteroPDFCandidate]) -> [PrimaryPDFSelection] {
        let grouped = Dictionary(grouping: candidates) { "\($0.libraryID):\($0.parentKey)" }
        var textSupplementCache: [String: Bool] = [:]
        return grouped.keys.sorted().compactMap { key in
            guard let group = grouped[key], let first = group.first else { return nil }
            let scored = sortByPrimaryPreference(group.map(score))

            let readable = scored.filter(\.isReadable)
            guard let top = readable.first else {
                return PrimaryPDFSelection(
                    parentID: key,
                    candidate: scored.first,
                    status: .failed,
                    reason: "No readable local PDF was resolved for \(first.title)."
                )
            }

            let second = readable.dropFirst().first
            let isCloseMatch = second.map { top.score - $0.score <= ambiguityScoreDelta } ?? false
            let noMetadataPrimary = readable.allSatisfy(isMetadataSupplemental)

            if isCloseMatch || noMetadataPrimary {
                let rescored = sortByPrimaryPreference(
                    readable.map {
                        score($0, includeCacheText: true, textSupplementCache: &textSupplementCache)
                    }
                )
                guard let rescoredTop = rescored.first else { return nil }

                let allReadableSupplemental = rescored.allSatisfy {
                    isSupplemental($0, includeCacheText: true, textSupplementCache: &textSupplementCache)
                }
                if allReadableSupplemental {
                    return PrimaryPDFSelection(
                        parentID: key,
                        candidate: rescoredTop,
                        status: .skippedSupplementalOnly,
                        reason: "Only supplemental/protocol-like PDFs were found. \(rescoredTop.selectionReason)"
                    )
                }

                let rescoredSecond = rescored.dropFirst().first
                if let rescoredSecond, rescoredTop.score - rescoredSecond.score <= ambiguityScoreDelta {
                    return PrimaryPDFSelection(
                        parentID: key,
                        candidate: rescoredTop,
                        status: .ambiguousPrimary,
                        reason: "The top two PDF candidates scored similarly (\(rescoredTop.score) vs \(rescoredSecond.score)). \(rescoredTop.selectionReason)"
                    )
                }

                return PrimaryPDFSelection(
                    parentID: key,
                    candidate: rescoredTop,
                    status: .queued,
                    reason: rescoredTop.selectionReason
                )
            }

            return PrimaryPDFSelection(
                parentID: key,
                candidate: top,
                status: .queued,
                reason: top.selectionReason
            )
        }
    }

    static func score(_ candidate: ZoteroPDFCandidate) -> ZoteroPDFCandidate {
        var textSupplementCache: [String: Bool] = [:]
        return score(candidate, includeCacheText: false, textSupplementCache: &textSupplementCache)
    }

    private static func score(
        _ candidate: ZoteroPDFCandidate,
        includeCacheText: Bool,
        textSupplementCache: inout [String: Bool]
    ) -> ZoteroPDFCandidate {
        var copy = candidate
        var score = 0
        var reasons: [String] = []

        if candidate.isReadable {
            score += 100
            reasons.append("readable")
        } else {
            score -= 1_000
            reasons.append("unreadable")
        }

        if candidate.linkMode == 0 || candidate.linkMode == 1 {
            score += 15
            reasons.append("stored in Zotero")
        }

        let attachmentTitle = candidate.attachmentTitle?.lowercased() ?? ""
        if attachmentTitle == "full text pdf" || attachmentTitle == "full-text pdf" {
            score += 70
            reasons.append("attachment title is Full Text PDF")
        } else if attachmentTitle == "pdf" || attachmentTitle == "full text" {
            score += 35
            reasons.append("attachment title indicates PDF")
        }

        let filename = candidate.resolvedURL?.lastPathComponent ?? candidate.rawPath ?? ""
        let lowerFilename = filename.lowercased()
        let lowerTitle = candidate.title.lowercased()
        let titleTokens = significantTokens(in: lowerTitle)
        let filenameMatches = titleTokens.filter { lowerFilename.contains($0) }.count
        if !titleTokens.isEmpty {
            let matchScore = min(40, filenameMatches * 8)
            score += matchScore
            if matchScore > 0 {
                reasons.append("filename matches \(filenameMatches) title token(s)")
            }
        }

        if isSupplemental(candidate, includeCacheText: includeCacheText, textSupplementCache: &textSupplementCache) {
            score -= 90
            reasons.append(includeCacheText ? "supplement/protocol-like metadata or text" : "supplement/protocol-like metadata")
        } else {
            score += 40
            reasons.append("not supplemental-looking")
        }

        if lowerFilename.range(of: #"(^|[/\s_-])media[-_\s]?\d"#, options: .regularExpression) != nil {
            score -= 60
            reasons.append("media attachment pattern")
        }

        if candidate.fileSize ?? 0 > 500_000 {
            score += 10
        }

        copy.score = score
        copy.selectionReason = "Score \(score): " + reasons.joined(separator: ", ")
        return copy
    }

    static func isSupplemental(_ candidate: ZoteroPDFCandidate) -> Bool {
        isMetadataSupplemental(candidate)
    }

    private static func isSupplemental(
        _ candidate: ZoteroPDFCandidate,
        includeCacheText: Bool,
        textSupplementCache: inout [String: Bool]
    ) -> Bool {
        if isMetadataSupplemental(candidate) {
            return true
        }

        guard includeCacheText else {
            return false
        }

        if let cached = textSupplementCache[candidate.id] {
            return cached
        }

        let detected = leadingCachedText(for: candidate).map(hasSupplementalDocumentHeading) ?? false
        textSupplementCache[candidate.id] = detected
        return detected
    }

    private static func isMetadataSupplemental(_ candidate: ZoteroPDFCandidate) -> Bool {
        let fields = [
            candidate.attachmentTitle ?? "",
            candidate.resolvedURL?.lastPathComponent ?? "",
            candidate.rawPath ?? ""
        ].joined(separator: " ").lowercased()

        let terms = [
            "supplement", "supplementary", "supporting information", "appendix",
            "protocol", "moesm", "mmc", "supinfo", "supp1", "supplemental",
            "figures", "tables", "dataset", "checklist"
        ]
        return terms.contains { fields.contains($0) }
    }

    private static func significantTokens(in text: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "with", "from", "into", "that", "this", "using",
            "based", "study", "analysis", "article", "paper", "between"
        ]
        return text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 && !stop.contains($0) }
    }

    private static func sortByPrimaryPreference(_ candidates: [ZoteroPDFCandidate]) -> [ZoteroPDFCandidate] {
        candidates.sorted {
            if $0.score == $1.score {
                return $0.attachmentItemID < $1.attachmentItemID
            }
            return $0.score > $1.score
        }
    }

    private static func leadingCachedText(for candidate: ZoteroPDFCandidate) -> String? {
        guard let cacheURL = candidate.cacheURL,
              let handle = try? FileHandle(forReadingFrom: cacheURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 16_384),
              !data.isEmpty else {
            return nil
        }

        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func hasSupplementalDocumentHeading(_ text: String) -> Bool {
        let leadingLines = text
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
            .prefix(25)

        let headingPatterns = [
            #"^supplement(ary|al)?\b"#,
            #"^supporting information\b"#,
            #"^appendix\b"#,
            #"^web (appendix|supplement)\b"#,
            #"^online supplement\b"#,
            #"^(table|figure|fig\.?|data|note|method|methods)\s+s\d+\b"#,
            #"^additional file\s+\d+\b"#
        ]

        return leadingLines.contains { line in
            headingPatterns.contains { pattern in
                line.range(of: pattern, options: .regularExpression) != nil
            }
        }
    }
}
