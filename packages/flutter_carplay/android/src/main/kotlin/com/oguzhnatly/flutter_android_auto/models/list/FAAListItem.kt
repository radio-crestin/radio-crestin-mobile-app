package com.oguzhnatly.flutter_android_auto

data class FAAListItemAction(
    val title: String,
    val iconName: String? = null,
    val isOnPressListenerActive: Boolean,
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAAListItemAction {
            val title = map["title"] as? String ?: ""
            val iconName = map["iconName"] as? String
            val isOnPressListenerActive = map["onPress"] as? Boolean ?: false
            return FAAListItemAction(title, iconName, isOnPressListenerActive)
        }
    }
}

data class FAAListItem(
    val elementId: String,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val isOnPressListenerActive: Boolean,
    val actions: List<FAAListItemAction> = emptyList(),
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAAListItem {
            val elementId = map["_elementId"] as? String ?: ""
            val title = map["title"] as? String ?: ""
            val subtitle = map["subtitle"] as? String
            val imageUrl = map["imageUrl"] as? String
            val isOnPressListenerActive = map["onPress"] as? Boolean ?: false
            val actionsRaw = map["actions"] as? List<*> ?: emptyList<Any>()
            val actions = actionsRaw.mapNotNull { raw ->
                (raw as? Map<String, Any?>)?.let { FAAListItemAction.fromJson(it) }
            }
            return FAAListItem(
                elementId, title, subtitle, imageUrl, isOnPressListenerActive, actions
            )
        }
    }
}
