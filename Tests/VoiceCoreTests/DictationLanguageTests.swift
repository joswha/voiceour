import Testing

@testable import VoiceCore

@Suite("Dictation language")
struct DictationLanguageTests {
    @Test(arguments: [
        ("I think we should ship the build after the tests pass.", DictationLanguage.english),
        ("Le comité a annoncé qu'il publierait les résultats dans la semaine.", .french),
        ("Die Ergebnisse werden nach der Sitzung auf der Webseite veröffentlicht.", .german),
        ("El equipo dijo que los resultados se publicarán en la página web.", .spanish),
        ("O comitê disse que os resultados serão publicados na página da escola.", .portuguese),
        ("Il comitato ha detto che i risultati saranno pubblicati nella pagina della scuola.", .italian),
        ("会議の結果は来週ウェブサイトで公開されます。", .japanese),
    ])
    func detectsEachLanguageFromItsOwnWords(text: String, language: DictationLanguage) {
        #expect(DictationLanguage.detect(text) == language)
    }

    /// Spelled letters, commands and identifiers are what short English dictations are made of;
    /// none of them may route a transcript away from the English rules.
    @Test(arguments: [
        "OK", "kubectl apply", "B. C. D. E. F.", "Y.", "Yo.", "Plus.", "Video plus.", "Dialogue act per.",
        "No make 'em work.", "So, um.", "L. c. d. screen.", "Um, F. N.", "",
    ])
    func leavesShortOrSpelledTextUndeterminedOrEnglish(text: String) {
        let language = DictationLanguage.detect(text)
        #expect(language == nil || language == .english, "\(text) → \(String(describing: language))")
        #expect(DictationLanguage.usesEnglishRules(language))
    }

    /// An English contraction is English; a French or Italian elision is not.
    @Test func readsApostrophesByLanguage() {
        #expect(DictationLanguage.detect("S'pose I try, said mister Hale, and don't you worry.") == .english)
        #expect(DictationLanguage.detect("C'est l'homme qu'il a vu dans la rue.") == .french)
        #expect(DictationLanguage.detect("L'anno scorso all'università c'era molto da fare.") == .italian)
    }

    @Test func portugueseUmIsAnArticleNotAFiller() {
        let text = "Ele comprou um carro e um livro para o filho."
        let language = DictationLanguage.detect(text)
        #expect(language == .portuguese)
        #expect(CleanupEngine.clean(text, glossary: [], language: language) == text)
        #expect(CleanupEngine.clean(text, glossary: []) == "Ele comprou carro e livro para o filho.")
    }

    /// FLEURS de_de: `um … zu` is a preposition and `die die` a relative pronoun and its article.
    @Test func germanKeepsUmZuAndGrammaticalRepeats() {
        let text = "Er kam früh, um den Zug zu sehen, und lobte die Gebäude, die die Stadt prägen."
        let language = DictationLanguage.detect(text)
        #expect(language == .german)
        #expect(CleanupEngine.clean(text, glossary: [], language: language) == text)
    }

    /// FLEURS fr_fr: a Glossary `Vue` turned "point de vue" into "point de Vue". A term spelled
    /// with letters and at most an initial capital is a word in some language, so another
    /// language's text keeps it; the same term still recases English prose.
    @Test func anotherLanguageKeepsWordShapedTermsAsSpoken() {
        let vue = ProtectedTerm(canonical: "Vue", spokenAliases: [])
        let french = "Elle partage son point de vue sur le projet."
        #expect(CleanupEngine.clean(french, glossary: [vue], language: .french) == french)
        #expect(CleanupEngine.clean("we ship vue components", glossary: [vue]) == "we ship Vue components")
        let pasteboard = ProtectedTerm(canonical: "NSPasteboard", spokenAliases: [])
        #expect(
            CleanupEngine.clean("Nous utilisons nspasteboard ici.", glossary: [pasteboard], language: .french)
                == "Nous utilisons NSPasteboard ici.")
    }

    /// Another language still gets whitespace normalization and its Glossary terms.
    @Test func otherLanguagesKeepTheLanguageNeutralCleanup() {
        let term = ProtectedTerm(canonical: "kubectl", spokenAliases: ["cube cuddle"], casePolicy: .exact)
        let text = "Nous  utilisons cube cuddle pour le déploiement."
        #expect(
            CleanupEngine.clean(text, glossary: [term], language: .french)
                == "Nous utilisons kubectl pour le déploiement.")
    }

    @Test func onlyEnglishAndUndeterminedKeepTheEnglishRules() {
        #expect(DictationLanguage.usesEnglishRules(nil))
        #expect(DictationLanguage.usesEnglishRules(.english))
        for language in DictationLanguage.allCases where language != .english {
            #expect(!DictationLanguage.usesEnglishRules(language))
        }
    }
}

@Suite("Dictation text stage")
struct DictationTextStageTests {
    private let repair = VocabularyRepairEngine(
        vocabulary: RepairVocabulary.fromActiveTerms(
            Settings.defaultGlossary, ordinaryWords: RepairVocabulary.bundledOrdinaryWords))

    private func stage(_ raw: String, cleanup: Bool = true) -> DictationTextStage.Outcome {
        DictationTextStage.apply(
            raw, cleanupEnabled: cleanup, glossary: Settings.defaultGlossary, repairEngine: cleanup ? repair : nil)
    }

    /// FLEURS es_419: the English `capital` command consumed a Spanish noun and uppercased the
    /// next word; Portuguese `um` is an article.
    @Test func anotherLanguageSkipsSpokenCommandsAndFillers() {
        let spanish = "Ottawa es la cautivadora capital bilingüe de Canadá y cuenta con muchos museos."
        #expect(stage(spanish) == .init(text: spanish, language: .spanish))
        #expect(stage(spanish, cleanup: false).text == spanish)
        let portuguese = "O scaffolding não é um método de aprendizado, mas sim uma ajuda para os alunos."
        #expect(stage(portuguese) == .init(text: portuguese, language: .portuguese))
    }

    @Test func englishAndUndeterminedKeepEveryRule() {
        #expect(
            stage("um so we use snake case voice capture")
                == .init(text: "so we use voice_capture", language: .english))
        #expect(stage("capital n s pasteboard") == .init(text: "NSPasteboard", language: nil))
        #expect(stage("Um, run cube cuddle.").text == "Run kubectl.")
    }
}
