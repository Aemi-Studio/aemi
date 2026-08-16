//
//  AutosizingPopoverContentModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 31/01/25.
//


import SwiftUI

struct AutosizingPopoverContentModifier<PopoverContent>: ViewModifier where PopoverContent: View {
    @Binding private(set) var isPresented: Bool
    private(set) var attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds)
    private(set) var arrowEdge: Edge?
    private(set) var fixedSize: FixedSize = .vertical
    private(set) var adaptation: PresentationAdaptation = .none
    @ViewBuilder let popoverContent: () -> PopoverContent

    private var horizontal: Bool { fixedSize == .horizontal || fixedSize == .both }
    private var vertical: Bool { fixedSize == .vertical || fixedSize == .both }

    @State private var size: CGSize? = .zero

    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) {
                popoverContent()
                    .update($size)
                    .fixedSize(horizontal: horizontal, vertical: vertical)
                    .frame(width: horizontal ? size?.width : nil, height: vertical ? size?.height : nil)
                    .presentationCompactAdaptation(adaptation)
            }
    }
}
