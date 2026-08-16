//
//  AutosizingSheetModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 31/01/25.
//

import SwiftUI

public extension View {
    func autosizingSheet(
        isPresented: Binding<Bool>,
        _ padding: EdgeInsets = .init(top: 16, leading: 16, bottom: 16, trailing: 16),
        fixedSize: FixedSize = .vertical,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(
            AutosizingSheetContentModifier(
                isPresented: isPresented,
                topPadding: padding.top,
                leadingPadding: padding.leading,
                bottomPadding: padding.bottom,
                trailingPadding: padding.trailing,
                fixedSize: fixedSize,
                sheetContent: content,
                onDismiss: onDismiss
            )
        )
    }

    func autosizingSheet(
        isPresented: Binding<Bool>,
        _ edge: Edge.Set = .all,
        _ length: CGFloat = 16,
        fixedSize: FixedSize = .vertical,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(
            AutosizingSheetContentModifier(
                isPresented: isPresented,
                topPadding: edge.contains(.top) ? length : 16,
                leadingPadding: edge.contains(.leading) ? length : 16,
                bottomPadding: edge.contains(.bottom) ? length : 16,
                trailingPadding: edge.contains(.trailing) ? length : 16,
                fixedSize: fixedSize,
                sheetContent: content,
                onDismiss: onDismiss
            )
        )
    }

    func autosizingSheet<Item>(
        _ item: Binding<Item?>,
        _ padding: EdgeInsets = .init(top: 16, leading: 16, bottom: 16, trailing: 16),
        fixedSize: FixedSize = .vertical,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View where Item: Identifiable {
        modifier(
            AutosizingSheetItemContentModifier(
                item: item,
                topPadding: padding.top,
                leadingPadding: padding.leading,
                bottomPadding: padding.bottom,
                trailingPadding: padding.trailing,
                fixedSize: fixedSize,
                sheetContent: content,
                onDismiss: onDismiss
            )
        )
    }

    func autosizingSheet<Item>(
        _ item: Binding<Item?>,
        _ edge: Edge.Set = .all,
        _ length: CGFloat = 16,
        fixedSize: FixedSize = .vertical,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View where Item: Identifiable {
        modifier(
            AutosizingSheetItemContentModifier(
                item: item,
                topPadding: edge.contains(.top) ? length : 16,
                leadingPadding: edge.contains(.leading) ? length : 16,
                bottomPadding: edge.contains(.bottom) ? length : 16,
                trailingPadding: edge.contains(.trailing) ? length : 16,
                fixedSize: fixedSize,
                sheetContent: content,
                onDismiss: onDismiss
            )
        )
    }
}
