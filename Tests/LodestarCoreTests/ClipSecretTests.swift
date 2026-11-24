import XCTest
@testable import LodestarCore

/// A secret on a card keeps its ends and draws its middle as blocks; the
/// things a hand copies to paste as they are — numbers, commits, paths,
/// links, names — are left alone.
final class ClipSecretTests: XCTestCase {
    private let b = ClipSecret.blocks

    private func mask(_ text: String) -> String? { ClipSecret.masked(text)?.text }

    // MARK: - Known formats keep their prefix

    func testKnownFormatsKeepPrefixAndTail() {
        XCTAssertEqual(mask("sk-proj-" + "AbCdEf1234567890GhIjKlMnOpQr"), "sk-proj-\(b)OpQr")
        XCTAssertEqual(mask("sk-ant-api03-" + "Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0Lz"), "sk-ant-api03-\(b)k0Lz")
        XCTAssertEqual(mask("ghp_" + "16C7e42F292c6912E7710c838347Ae178B4a"), "ghp_\(b)8B4a")
        XCTAssertEqual(mask("github_pat_" + "11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCD"),
                       "github_pat_\(b)ABCD")
        XCTAssertEqual(mask("sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc"), "sk_live_\(b)p7dc")
        XCTAssertEqual(mask("AKIA" + "IOSFODNN7EXAMPLE"), "AKIA\(b)PLE", "a short body keeps a fifth of itself")
        XCTAssertEqual(mask("xoxb-" + "123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"), "xoxb-\(b)UvWx")
        XCTAssertEqual(mask("hf_" + "AbCdEfGhIjKlMnOpQrStUvWxYzAbCdEfGh"), "hf_\(b)EfGh")
        XCTAssertEqual(mask("re_" + "Ab12Cd34_Ef56Gh78Ij90Kl12Mn34Op56"), "re_\(b)Op56")
        XCTAssertEqual(mask("lin_api_" + "AbCdEf1234567890GhIjKlMnOpQrStUv"), "lin_api_\(b)StUv",
                       "a secret's own prefix is read before the object-id rule")
    }

    func testAJSONWebToken() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertEqual(mask(jwt), "eyJ\(b)sR8U")
    }

    func testAPrefixInsideAWordIsNotAKey() {
        XCTAssertNil(mask("ask-me-anything-about-the-release"), "sk- inside a word")
        XCTAssertNil(mask("re_render_the_whole_card_again"), "a snake-case name that starts like a Resend key")
        XCTAssertNil(mask("sk-learn-classification-tutorial"), "a slug with no digit")
    }

    // MARK: - Labelled values

    func testALabelSaysWhatFollowsIsSecret() {
        XCTAssertEqual(mask("password: hunter2!x"), "password: h\(b)x")
        XCTAssertEqual(mask("DATABASE_PASSWORD=correcthorse"), "DATABASE_PASSWORD=co\(b)se")
        XCTAssertEqual(mask(#"{"client_secret": "a1b2c3d4e5f6g7h8"}"#), "{\"client_secret\": \"a1b\(b)7h8\"}")
        XCTAssertEqual(mask("Passcode: 482913"), "Passcode: 4\(b)3", "a labelled passcode is secret even as digits")
        XCTAssertEqual(mask("the password is tr0ub4dor&3"), "the password is tr\(b)&3")
    }

    func testBearerAndURLPasswords() {
        XCTAssertEqual(mask("Authorization: Bearer abc.def-ghi_jkl~mno"),
                       "Authorization: Bearer abc\(b)mno")
        XCTAssertEqual(mask("postgres://admin:s3cretPass@db.example.com/app"),
                       "postgres://admin:s3\(b)ss@db.example.com/app")
        XCTAssertEqual(mask("https://us02web.zoom.us/j/81234567890?pwd=AbCdEf123456GhIj"),
                       "https://us02web.zoom.us/j/81234567890?pwd=AbC\(b)hIj")
    }

    func testLabelsThatAreNotSecrets() {
        XCTAssertNil(mask("max_tokens: 4096"))
        XCTAssertNil(mask("tokenizer: gemma"))
        XCTAssertNil(mask("password: ${DB_PASSWORD}"), "a reference to where the secret lives")
        XCTAssertNil(mask("API_KEY=process.env.OPENAI_KEY"))
        XCTAssertNil(mask("password: ********"), "already hidden")
        XCTAssertNil(mask("password: required"))
    }

    // MARK: - Random-looking runs

    func testARandomRunKeepsItsEnds() {
        XCTAssertEqual(mask("Zk3mQ9vT2pLx8RwN4bYc"), "Zk3m\(b)4bYc")
        XCTAssertEqual(mask("export KEY 9dK2/xQv7+Lm3RtPzW8nYb4Hc1Fg6JkSaE0uTo5i=="),
                       "export KEY 9dK2\(b)To5i==", "the padding is not the key")
    }

    func testWhatAHandMeansToPasteIsLeftAlone() {
        let plain = [
            "4111111111111111",                                  // digits: a card number, an order
            "1788360998533125900",                                // a timestamp
            "de595f9a1b2c3d4e5f60718293a4b5c6d7e8f901",           // a commit
            "123e4567-e89b-12d3-a456-426614174000",               // a UUID
            "fetchUserProfile2024Handler",                        // a name
            "local/clipboard-secrets",                            // a branch
            "Sources/LodestarCore/ClipSecret.swift",              // a path
            "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-ab/edit", // a link
            "swift build -c release --arch arm64",
            "AB12CD34EF",                                         // too short to tell
            "ORDER-2026-000123-A",                                // an order
            "The quick brown fox jumps over the lazy dog.",
            "ClipboardStripTests.testSecretCardsDrawBlocks2",
            "user_2NNEqL2nrIRdJ194ndJqAHwEfxC",                   // an object id: Clerk
            "cus_NffrFeUfNV2Hib4a",                               // Stripe
            "pk_test_" + "51HqLyjWDarjtT1zdp7dcAbCdEf",                // a publishable key is public
            "5-40-AB-123-ab-1CD-abcde1-XYZ",                      // a record built of fields
            "PROJ-2026-09-29_1432-17-05",
        ]
        for text in plain {
            XCTAssertNil(mask(text), text)
        }
    }

    // MARK: - Within a longer clip

    func testOnlyTheSecretIsHidden() {
        let curl = "curl https://api.example.com/v1/items -H \"Authorization: Bearer Zk3mQ9vT2pLx8RwN4bYc\" -d '{}'"
        XCTAssertEqual(mask(curl),
                       "curl https://api.example.com/v1/items -H \"Authorization: Bearer Zk3m\(b)4bYc\" -d '{}'")
        let env = "APP_ENV=production\nSTRIPE_KEY=sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc\nPORT=8080"
        XCTAssertEqual(mask(env), "APP_ENV=production\nSTRIPE_KEY=sk_live_\(b)p7dc\nPORT=8080")
    }

    func testAPrivateKeyKeepsItsArmour() {
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDwexampleexampleexampleexampleexampleexampleAAAA
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertEqual(mask(key), "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b)\n-----END OPENSSH PRIVATE KEY-----")
    }

    func testTheBlocksAreWhereTheMaskSaysTheyAre() throws {
        let masked = try XCTUnwrap(ClipSecret.masked("a: Zk3mQ9vT2pLx8RwN4bYc and ghp_" + "16C7e42F292c6912E7710c838347Ae178B4a"))
        XCTAssertEqual(masked.blocks.count, 2)
        for range in masked.blocks {
            XCTAssertEqual((masked.text as NSString).substring(with: range), b)
        }
    }

    func testTheClipIsSearchedWhole() {
        // The mask is drawn, never stored: the clip keeps its whole text,
        // and the search reads it.
        let clip = Clipboard.Clip(id: "k", kind: .text, created: Date(), sourceBundleID: nil,
                                  sourceAppName: nil, preview: "Zk3mQ9vT2pLx8RwN4bYc", bytes: 20)
        XCTAssertEqual(clip.preview, "Zk3mQ9vT2pLx8RwN4bYc")
        XCTAssertNotNil(clip.masked)
        let image = Clipboard.Clip(id: "i", kind: .image, created: Date(), sourceBundleID: nil,
                                   sourceAppName: nil, preview: "image 10×10\nZk3mQ9vT2pLx8RwN4bYc", bytes: 20)
        XCTAssertNil(image.masked, "an image's caption is never drawn")
    }

    func testEndsNeverShowMostOfASecret() {
        XCTAssertEqual(ClipSecret.ends(4), 0)
        XCTAssertEqual(ClipSecret.ends(9), 1)
        XCTAssertEqual(ClipSecret.ends(16), 3)
        XCTAssertEqual(ClipSecret.ends(40), 4)
    }
}
