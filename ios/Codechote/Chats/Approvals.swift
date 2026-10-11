import SwiftUI

/// Several blocked tool calls from one turn, answered together or one by one.
struct ApprovalsCard: View {
    let agent: AgentKind
    let requests: [PermissionRequest]
    let onApprove: ([PermissionRequest], Bool) -> Void
    let onDecline: (PermissionRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(agent.title) needs \(requests.count) approvals").font(.subheadline.weight(.semibold))
            }
            ForEach(requests) { request in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.tool).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(request.summary.isEmpty ? "No details were given." : request.summary)
                            .font(.system(.footnote, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button { onApprove([request], false) } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.bordered).accessibilityLabel("Allow \(request.summary)")
                    Button(role: .destructive) { onDecline(request) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.bordered).accessibilityLabel("Decline \(request.summary)")
                }
                .padding(10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button { onApprove(requests, false) } label: { Text("Allow All").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { onApprove(requests, true) } label: { Text("Always in This Chat").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1) }
    }
}

/// Shown when an agent was blocked from running a tool. Approving lets it retry with exactly that permission.
struct ApprovalCard: View {
    let agent: AgentKind
    let request: PermissionRequest
    let onAllow: () -> Void
    let onAlways: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(agent.title) needs your approval").font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(request.tool).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(request.summary.isEmpty ? "No details were given." : request.summary)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Button(action: onAllow) { Text("Allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button(action: onAlways) { Text("Always in This Chat").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button(role: .destructive, action: onDecline) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Decline")
            }
            .controlSize(.regular)
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}
