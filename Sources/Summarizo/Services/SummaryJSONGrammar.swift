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

    static let spanSelection = #"""
    root ::= object
    object ::= "{" ws "\"start_id\"" ws ":" ws int ws "," ws "\"end_id\"" ws ":" ws int ws "," ws "\"confidence\"" ws ":" ws confidence ws "}"
    int ::= [0-9]+
    confidence ::= "\"high\"" | "\"medium\"" | "\"low\""
    ws ::= [ \t\n\r]*
    """#
}
