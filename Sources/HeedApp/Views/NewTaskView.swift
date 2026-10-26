import HeedCore
import SwiftUI

/// The new task dialog (`o`): only a title. Draws `AppModel.newTask`; keys reach the form through the key router,
/// never through a text field, so focus never leaves the window's one key path.
struct NewTaskView: View {
    @Environment(AppModel.self) private var model
    let form: NewTaskForm

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .onTapGesture { model.cancelNewTask() }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("New task").font(Theme.ui(15, weight: .semibold))
                    Spacer()
                    KeyCap(text: "↩")
                    Text("create").foregroundStyle(Theme.fg2)
                    KeyCap(text: "⎋")
                    Text("cancel").foregroundStyle(Theme.fg2)
                }
                .font(Theme.ui(12))
                .padding(20)
                (Text(form.title.isEmpty ? "Title" : form.title)
                    .foregroundStyle(form.title.isEmpty ? Theme.fg3 : Theme.fg)
                    + Text("▌").foregroundStyle(Theme.done))
                    .font(Theme.mono(14))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.pane))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fg2))
                    .padding(.horizontal, 20)
                if !form.context.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FIRST PROMPT").font(Theme.ui(11, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(Theme.fg3)
                        Text(form.context).font(Theme.mono(12)).foregroundStyle(Theme.fg2).lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                Group {
                    if let error = form.error {
                        Text(error).foregroundStyle(Theme.err)
                    } else {
                        Text("Starts claude in \(Paths.abbreviate(Kibana.mainCheckout)).")
                            .foregroundStyle(Theme.fg3)
                    }
                }
                .font(Theme.ui(12))
                .padding(20)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.dialog)
        }
    }
}
