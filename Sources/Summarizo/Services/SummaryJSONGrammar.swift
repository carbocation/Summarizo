enum SummaryJSONGrammar {
    static let shared = #"""
    root ::= object
    object ::= "{" ws "\"summary\"" ws ":" ws string ws "}"
    string ::= "\"" chars "\""
    chars ::= char*
    char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)
    hex ::= [0-9a-fA-F]
    ws ::= [ \t\n\r]*
    """#

    static let sectionClassification = #"""
    root ::= object
    object ::= "{" ws "\"section_type\"" ws ":" ws section ws "}"
    section ::= "\"front\"" | "\"methods_results\"" | "\"back\"" | "\"other\""
    ws ::= [ \t\n\r]*
    """#
}
