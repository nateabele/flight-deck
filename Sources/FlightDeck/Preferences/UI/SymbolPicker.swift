import SwiftUI

/// A button showing the current symbol, opening a searchable grid.
struct SymbolPicker: View {
    @Binding var symbol: String
    @State private var isPresented = false
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 6), count: 7)

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .accessibilityIdentifier("tool-symbol-picker")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(SymbolCatalog.matching(query)) { entry in
                            Button {
                                symbol = entry.name
                                isPresented = false
                            } label: {
                                Image(systemName: entry.name)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(entry.name == symbol ? Color.accentColor.opacity(0.25) : .clear)
                                    )
                            }
                            .buttonStyle(.borderless)
                            .help(entry.name)
                        }
                    }
                }
                .frame(width: 260, height: 180)
            }
            .padding(10)
        }
    }
}
