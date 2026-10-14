import FleetKit
import SwiftUI

/// The Rounds inspector (read-only): every agent a round configuration runs, with its model,
/// effort and fallback, then the caps and the default play. Reached from the intake's "Rounds"
/// row, or from the fidelity chooser for the configuration a fidelity WOULD run (`preset`).
struct RoundInspectorScreen: View {
    let intake: UUID
    let preset: String?
    let model: IntakeDetailModel
    let flightControl: FlightControlModel

    private var config: WireRoundConfig? {
        guard let detail = model.detail else { return nil }
        if let preset { return detail.choice?.presets?.first { $0.preset == preset }?.config }
        return detail.roundConfig
    }

    var body: some View {
        let inspector = config.map { RoundInspectorModel.make(preset: preset ?? model.detail?.summary.preset, config: $0) }
        List {
            if let inspector {
                ForEach(inspector.stages) { stage in
                    Section(stage.title) {
                        ForEach(stage.agents) { agent in
                            HStack(alignment: .top, spacing: 10) {
                                if agent.rotation.isEmpty {
                                    AgentIcon(agent: agent.agent, size: 28)
                                } else {
                                    Color.clear.frame(width: 28, height: 28)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(agent.role).font(.subheadline)
                                        if let persona = agent.persona {
                                            Text(persona).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(agent.line).font(.caption).foregroundStyle(.secondary)
                                    // A rotating role: its agents in turn, each with its icon.
                                    ForEach(agent.rotation) { alternate in
                                        HStack(spacing: 6) {
                                            AgentIcon(agent: alternate.agent, size: 20)
                                            Text(alternate.line).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    if let fallback = agent.fallback {
                                        HStack(spacing: 4) {
                                            if let other = agent.fallbackAgent { AgentIcon(agent: other, size: 14) }
                                            Text(fallback).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        ForEach(stage.facts, id: \.label) { fact(label: $0.label, value: $0.value) }
                    }
                }
                Section {
                    ForEach(inspector.settings, id: \.label) { fact(label: $0.label, value: $0.value) }
                }
            } else if model.detail != nil {
                Section {
                    Text("Your Mac hasn't sent the agents for this yet.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(inspector?.title ?? "Rounds")
        .navigationBarTitleDisplayMode(.inline)
        .intakePresence(id: intake, model: model, flightControl: flightControl)
    }

    private func fact(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
