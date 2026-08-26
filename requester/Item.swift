//
//  Item.swift
//  requester
//
//  Created by Vladyslav Prymov on 26/08/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
