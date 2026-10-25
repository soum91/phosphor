import SwiftUI
import WidgetKit
import AppIntents

@available(iOS 18.0, *)
struct TVHomeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.phosphor.TVHomeControl") {
            ControlWidgetButton(action: PressButtonIntent(key: "Home")) { Label("TV Home", systemImage: "house.fill") }
        }.displayName("TV Home").description("TV Home")
    }
}
