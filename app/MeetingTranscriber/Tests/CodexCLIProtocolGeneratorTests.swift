#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    final class CodexCLIProtocolGeneratorTests: XCTestCase {
        private func withCLI<T>(script: String, body: (String) async throws -> T) async throws -> T {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let binary = directory.appendingPathComponent("codex")
            try ("#!/usr/bin/python3\n" + script).write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            return try await body(binary.path)
        }

        func testLargeTranscriptAndDiagnosticsDoNotDeadlockOrContaminateSummary() async throws {
            try await withCLI(script: """
            import sys
            prompt=sys.stdin.read()
            assert len(prompt)>200000 and 'Russian' in prompt
            assert '--ignore-user-config' in sys.argv
            assert '--sandbox' in sys.argv and 'read-only' in sys.argv
            sys.stdout.write('diagnostic'*30000)
            sys.stderr.write('private diagnostic'*30000)
            output=sys.argv[sys.argv.index('--output-last-message')+1]
            open(output,'w').write('  # Summary\\nDecision.  ')
            """) { binary in
                let generator = CodexCLIProtocolGenerator(codexBin: binary, language: "Russian", timeoutSeconds: 5)
                let result = try await generator.generate(
                    transcript: String(repeating: "meeting ", count: 30000), title: "Test", diarized: false, meetingStartTime: nil,
                )
                XCTAssertEqual(result, "# Summary\nDecision.")
            }
        }

        func testFailureDoesNotExposeTranscriptFromDiagnostics() async throws {
            try await withCLI(script: "import sys\nsys.stderr.write('PRIVATE TRANSCRIPT')\nsys.exit(7)") { binary in
                do {
                    _ = try await CodexCLIProtocolGenerator(codexBin: binary, language: "Russian")
                        .generate(transcript: "secret", title: "", diarized: false, meetingStartTime: nil)
                    XCTFail("Expected nonzero exit")
                } catch {
                    XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
                    XCTAssertTrue(error.localizedDescription.contains("7"))
                }
            }
        }

        func testSilentProcessTimesOut() async throws {
            try await withCLI(script: "import time\ntime.sleep(30)") { binary in
                let start = Date()
                do {
                    _ = try await CodexCLIProtocolGenerator(codexBin: binary, language: "Russian", timeoutSeconds: 0.2)
                        .generate(transcript: "", title: "", diarized: false, meetingStartTime: nil)
                    XCTFail("Expected timeout")
                } catch CodexCLIError.timeout {
                    XCTAssertLessThan(Date().timeIntervalSince(start), 3)
                }
            }
        }

        func testSuccessfulExitWithoutFinalMessageFails() async throws {
            try await withCLI(script: "print('diagnostics are not a summary')") { binary in
                do {
                    _ = try await CodexCLIProtocolGenerator(codexBin: binary, language: "Russian")
                        .generate(transcript: "", title: "", diarized: false, meetingStartTime: nil)
                    XCTFail("Expected empty summary")
                } catch ProtocolError.emptyProtocol {}
            }
        }

        func testProviderAndBinaryPersist() throws {
            let suite = "CodexProviderTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { DefaultsSuite.remove(suite) }
            let settings = AppSettings(defaults: defaults, apiKeyAccount: suite, claudeAPIKeyAccount: suite + ".claude")
            settings.protocolProvider = .codexCLI
            settings.codexBin = "/custom/codex"
            let restored = AppSettings(defaults: defaults, apiKeyAccount: suite, claudeAPIKeyAccount: suite + ".claude")
            XCTAssertEqual(restored.protocolProvider, .codexCLI)
            XCTAssertEqual(restored.codexBin, "/custom/codex")
        }
    }
#endif
