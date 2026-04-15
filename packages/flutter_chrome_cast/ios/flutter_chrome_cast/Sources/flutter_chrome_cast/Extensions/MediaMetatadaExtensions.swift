//
//  MediaMetatadaExtensions.swift
//  google_cast
//
//  Created by LUIZ FELIPE ALVES LIMA on 28/06/22.
//

import Foundation
import GoogleCast



extension GCKMediaMetadata {
    func toMap() -> Dictionary<String,Any?> {
        var dict = Dictionary<String,Any?>()
        dict["type"] = self.metadataType.rawValue
        dict["images"] =  (self.images() as! [GCKImage]).map{
            image in
            image.toMap()
            
        }
        let creationDate = self.date(forKey: kGCKMetadataKeyCreationDate)
        let releaseDate = self.date(forKey: kGCKMetadataKeyReleaseDate)
        let broadCastDate = self.date(forKey: kGCKMetadataKeyBroadcastDate)
        let title = self.string(forKey: kGCKMetadataKeyTitle)
        let subtitle = self.string(forKey: kGCKMetadataKeySubtitle)
        let artist = self.string(forKey: kGCKMetadataKeyArtist)
        let albumArtist = self.string(forKey: kGCKMetadataKeyAlbumArtist)
        let albumTitle = self.string(forKey: kGCKMetadataKeyAlbumTitle)
        let albumComposer = self.string(forKey: kGCKMetadataKeyComposer)
        let albumDiscNumber = self.integer(forKey: kGCKMetadataKeyDiscNumber)
        let albumTrackNumber = self.integer(forKey: kGCKMetadataKeyTrackNumber)
        let seasonNumber = self.integer(forKey: kGCKMetadataKeySeasonNumber)
        let episodeNumber = self.integer(forKey: kGCKMetadataKeyEpisodeNumber)
        let serieTitle = self.string(forKey: kGCKMetadataKeySeriesTitle)
        let studio = self.string(forKey: kGCKMetadataKeyStudio)
        let width = self.string(forKey: kGCKMetadataKeyWidth)
        let height = self.string(forKey: kGCKMetadataKeyHeight)
        let locationName = self.string(forKey: kGCKMetadataKeyLocationName)
        let locationLatitude = self.double(forKey: kGCKMetadataKeyLocationLatitude)
        let locationLongitude = self.double(forKey: kGCKMetadataKeyLocationLongitude)
        dict["creationDate"] = creationDate?.timeIntervalSince1970
        dict["releaseDate"] = releaseDate?.timeIntervalSince1970
        dict["broadcastDate"] = broadCastDate?.timeIntervalSince1970
        dict["title"] = title
        dict["subtitle"] = subtitle
        dict["artist"] = artist
        dict["albumArtist"] = albumArtist
        dict["albumTitle"] = albumTitle
        dict["composer"] = albumComposer
        dict["discNumber"] = albumDiscNumber
        dict["trackNumber"] = albumTrackNumber
        dict["seasonNumber"] = seasonNumber
        dict["episodeNumber"] = episodeNumber
        dict["serieTitle"] = serieTitle
        dict["studio"] = studio
        dict["width"] = width
        dict["height"] = height
        dict["locationName"] = locationName
        dict["locationLatitude"] = locationLatitude
        dict["locationLongitude"] = locationLongitude
        return dict
        
    }
    
    
    /// Maps Dart key names to the standard Cast SDK GCK metadata key constants.
    /// Without this, setString(v, forKey: "title") stores under a custom key
    /// instead of kGCKMetadataKeyTitle and the receiver never sees standard fields.
    private static let keyMapping: [String: String] = [
        "title": kGCKMetadataKeyTitle,
        "subtitle": kGCKMetadataKeySubtitle,
        "artist": kGCKMetadataKeyArtist,
        "albumArtist": kGCKMetadataKeyAlbumArtist,
        "albumName": kGCKMetadataKeyAlbumTitle,
        "composer": kGCKMetadataKeyComposer,
        "seriesTitle": kGCKMetadataKeySeriesTitle,
        "studio": kGCKMetadataKeyStudio,
        "locationName": kGCKMetadataKeyLocationName,
    ]

    private static let intKeyMapping: [String: String] = [
        "trackNumber": kGCKMetadataKeyTrackNumber,
        "discNumber": kGCKMetadataKeyDiscNumber,
        "seasonNumber": kGCKMetadataKeySeasonNumber,
        "episodeNumber": kGCKMetadataKeyEpisodeNumber,
        "width": kGCKMetadataKeyWidth,
        "height": kGCKMetadataKeyHeight,
    ]

    private static let doubleKeyMapping: [String: String] = [
        "locationLatitude": kGCKMetadataKeyLocationLatitude,
        "locationLongitude": kGCKMetadataKeyLocationLongitude,
    ]

    private static let dateKeys: Set<String> = [
        "broadcastDate", "releaseDate", "creationDate", "creationDateTime"
    ]

    private static let skipKeys: Set<String> = [
        "metadataType", "images"
    ]

    static func fromMap(_ imulatbleDict : Dictionary<String, Any >) ->  GCKMediaMetadata? {
        var mutableDict = imulatbleDict

       guard let metadataTypeValue = mutableDict["metadataType"] as? Int,
             let metadataType = GCKMediaMetadataType(rawValue: metadataTypeValue) else {
           return nil
       }
        let metadata = GCKMediaMetadata(metadataType: metadataType)

        // Images
        if let images = mutableDict["images"] as? [Dictionary<String, Any>] {
            for image in images {
                guard let url = URL(string: image["url"] as? String ?? "" ) else {
                    continue
                }
                metadata.addImage(GCKImage(url: url, width: image["width"] as? Int ?? 0 , height: image["height"] as? Int ?? 0 ))
            }
        }

        // All other fields — map Dart keys to standard GCK constants
        for mapValue in mutableDict {
            if skipKeys.contains(mapValue.key) { continue }

            // Date fields
            if dateKeys.contains(mapValue.key) {
                if let timeInterval = mapValue.value as? Double {
                    let date = Date(timeIntervalSince1970: timeInterval / 1000)
                    switch mapValue.key {
                    case "broadcastDate":
                        metadata.setDate(date, forKey: kGCKMetadataKeyBroadcastDate)
                    case "releaseDate":
                        metadata.setDate(date, forKey: kGCKMetadataKeyReleaseDate)
                    case "creationDate", "creationDateTime":
                        metadata.setDate(date, forKey: kGCKMetadataKeyCreationDate)
                    default:
                        break
                    }
                }
                continue
            }

            // String, Int, Double fields — use SDK key mapping
            switch mapValue.value {
            case let stringValue as String:
                let sdkKey = keyMapping[mapValue.key] ?? mapValue.key
                metadata.setString(stringValue, forKey: sdkKey)
            case let intValue as Int:
                let sdkKey = intKeyMapping[mapValue.key] ?? mapValue.key
                metadata.setInteger(intValue, forKey: sdkKey)
            case let doubleValue as Double:
                let sdkKey = doubleKeyMapping[mapValue.key] ?? mapValue.key
                metadata.setDouble(doubleValue, forKey: sdkKey)
            default:
                break
            }
        }

        return metadata
    }
}
