import SwiftUI

struct OverlayView: View {
    @Environment(AppModel.self) private var model

    private var channelBinding: Binding<String> {
        Binding<String>(
            get: { model.selectedChannel },
            set: { (newValue: String) in model.setChannel(newValue) }
        )
    }

    private var unitBinding: Binding<SpeedUnit> {
        Binding<SpeedUnit>(
            get: { model.speedUnit },
            set: { (newValue: SpeedUnit) in model.setSpeedUnit(newValue) }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            controls
            if model.checkedLaps.isEmpty {
                Spacer()
                Text("Check one or more laps to overlay them.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    charts
                    sidePanel
                }
            }
        }
        .padding(12)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Channel", selection: channelBinding) {
                ForEach(model.availableChannels, id: \.self) { (name: String) in
                    Text(name).tag(name)
                }
            }
            .frame(width: 280)
            Picker("Speed", selection: unitBinding) {
                ForEach(SpeedUnit.allCases) { (u: SpeedUnit) in
                    Text(u.label).tag(u)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Spacer()
        }
    }

    private var charts: some View {
        VStack(spacing: 10) {
            SeriesChartView(
                title: model.channelAxisLabel,
                yLabel: model.selectedChannel,
                series: model.analysis.channelSeries,
                xMax: model.analysis.xMax,
                showZeroLine: false,
                showLegend: true
            )
            .frame(minHeight: 220)
            SeriesChartView(
                title: "Time delta vs reference (s), positive = behind",
                yLabel: "Delta",
                series: model.analysis.deltaSeries,
                xMax: model.analysis.xMax,
                showZeroLine: true,
                showLegend: false
            )
            .frame(minHeight: 150, maxHeight: 240)
        }
    }

    private var sidePanel: some View {
        VStack(spacing: 10) {
            TrackMapView()
                .frame(height: 260)
            ReadoutView()
        }
        .frame(width: 300)
    }
}
