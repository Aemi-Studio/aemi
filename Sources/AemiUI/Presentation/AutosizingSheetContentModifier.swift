//
//  AutosizingSheetContentModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 31/01/25.
//

import SwiftUI

struct AutosizingSheetContentModifier<SheetContent>: ViewModifier where SheetContent: View {
    @Binding private(set) var isPresented: Bool
    private(set) var topPadding: CGFloat = 0
    private(set) var leadingPadding: CGFloat = 0
    private(set) var bottomPadding: CGFloat = 0
    private(set) var trailingPadding: CGFloat = 0
    private(set) var fixedSize: FixedSize = .vertical
    @ViewBuilder let sheetContent: () -> SheetContent
    private(set) var onDismiss: () -> Void = {}

    private var horizontal: Bool { fixedSize == .horizontal || fixedSize == .both }
    private var vertical: Bool { fixedSize == .vertical || fixedSize == .both }

    @State private var size: CGSize? = .zero

    private var height: CGFloat {
        (size?.height ?? 0) + topPadding + bottomPadding
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                sheetContent()
                    .padding(
                        EdgeInsets(
                            top: topPadding, leading: leadingPadding, bottom: bottomPadding, trailing: trailingPadding
                        )
                    )
                    .update($size)
                    .fixedSize(horizontal: horizontal, vertical: vertical)
                    .frame(width: horizontal ? size?.width : nil, height: vertical ? size?.height : nil)
                    .presentationDetents([.height(height)])
            }
    }
}
