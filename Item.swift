//
//  Item.swift
//  EvaLedger
//
//  Created by Burak on 6.10.2026.
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
