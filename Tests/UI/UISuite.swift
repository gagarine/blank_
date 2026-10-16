import AppKit
import BlankTestSupport
@testable import BlankNative
@testable import BlankIntegrationTests

@MainActor public enum UISuite {
    public static func main() {
        setbuf(stdout,nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let state = VerificationState(clipboard:true)
        if CommandLine.arguments.contains("--restore-state") { state.restore(); return }
        let args = CommandLine.arguments
        let prepare = args.contains("--draft-lifecycle-prepare")
        let verify = args.contains("--draft-lifecycle-verify")
        let disabled = args.contains("--draft-lifecycle-disabled-verify")
        BlankApplication.run(restore:verify || disabled) { object in
            let app = object as! AppController
            guard let controller = app.controllers.first else { fatalError("Missing interactive native host") }
            if args.contains(where:{ $0.hasSuffix("ui-test") }) {
                if args.contains("--selection-style-ui-test") { NativeSelectionStyleAcceptance.showFixture(controller:controller) }
                if args.contains("--format-ui-test") { NativeSaveFormatAcceptance.showFixture(controller) }
                if args.contains("--image-sizing-ui-test") { NativeImageSizingAcceptance.showFixture(controller) }
                if args.contains("--quicklook-ui-test") { NativeQuickLookAcceptance.showFixture(controller) }
                if args.contains("--figure-ui-test") { NativeFigureAcceptance.showFixture(controller:controller) }
                if args.contains("--reference-ui-test") { NativeReferenceAcceptance.showFixture(controller:controller) }
                if args.contains("--paragraph-space-ui-test") { NativeParagraphSpaceAcceptance.showFixture(controller:controller) }
                if args.contains("--citation-ui-test") { NativeCitationAcceptance.showFixture(controller:controller) }
                return
            }
            if prepare { NativeDraftUIAcceptance.prepare() }
            else if verify { NativeDraftAcceptance.verify() }
            else if disabled { NativeDraftAcceptance.verifyDisabledLaunch() }
            else if args.contains("--image-sizing-self-test") { NativeImageSizingAcceptance.run(controller) }
            else if args.contains("--preview-self-test") { NativePreviewAcceptance.run(controller) }
            else if args.contains("--format-self-test") { NativeSaveFormatAcceptance.run(controller) }
            else if args.contains("--find-self-test") { NativeFindAcceptance.run(original:controller) }
            else if args.contains("--paragraph-space-self-test") { NativeParagraphSpaceAcceptance.run(original:controller) }
            else if args.contains("--selection-style-self-test") { NativeSelectionStyleAcceptance.run(controller:controller) }
            else if args.contains("--block-source-self-test") { NativeBlockSourceAcceptance.run(controller:controller) }
            else if args.contains("--label-self-test") { NativeLabelAcceptance.run(controller:controller) }
            else if args.contains("--reference-self-test") { NativeReferenceAcceptance.run(controller:controller) }
            else if args.contains("--figure-self-test") { NativeFigureAcceptance.run(controller:controller) }
            else if args.contains("--template-self-test") {
                NativeTemplateAcceptance.run(original:controller) { library,chooser,starters in try NativeTemplateUIAcceptance.run(original:controller,library:library,chooser:chooser,starters:starters) }
            }
            else { NativeAcceptance.run(controller:controller) }
            state.restore(preferences:!prepare && !verify)
            exit(0)
        }
    }
}
