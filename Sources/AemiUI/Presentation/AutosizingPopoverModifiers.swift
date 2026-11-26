//
//  AutosizingPopoverModifiers.swift
//  AemiUI
//
//  Created by Gigi on 31/01/25.
//

#if canImport(SwiftUI)
    import SwiftUI

    extension View {
        public func autosizingPopover(
            isPresented: Binding<Bool>,
            attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
            arrowEdge: Edge? = nil,
            fixedSize: FixedSize = .vertical,
            content: @escaping () -> some View
        ) -> some View {
            modifier(
                AutosizingPopoverContentModifier(
                    isPresented: isPresented,
                    attachmentAnchor: attachmentAnchor,
                    arrowEdge: arrowEdge,
                    fixedSize: fixedSize,
                    popoverContent: content
                )
            )
        }

        public func autosizingPopover<Item>(
            item: Binding<Item?>,
            attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
            arrowEdge: Edge? = nil,
            fixedSize: FixedSize = .vertical,
            content: @escaping (Item) -> some View
        ) -> some View where Item: Identifiable {
            modifier(
                AutosizingPopoverItemContentModifier(
                    item: item,
                    attachmentAnchor: attachmentAnchor,
                    arrowEdge: arrowEdge,
                    fixedSize: fixedSize,
                    popoverContent: content
                )
            )
        }
    }
#endif
