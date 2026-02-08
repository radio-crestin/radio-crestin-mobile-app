package com.oguzhnatly.flutter_android_auto

data class FAAGridButton(
    val elementId: String,
    val title: String,
    val imageUrl: String? = null,
    val isOnPressListenerActive: Boolean,
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAAGridButton {
            val elementId = map["_elementId"] as? String ?: ""
            val title = map["title"] as? String ?: ""
            val imageUrl = map["imageUrl"] as? String
            val isOnPressListenerActive = map["onPress"] as? Boolean ?: false
            return FAAGridButton(elementId, title, imageUrl, isOnPressListenerActive)
        }
    }
}
