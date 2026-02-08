package com.oguzhnatly.flutter_android_auto

data class FAAGridTemplate(
    val elementId: String,
    val title: String,
    val buttons: List<FAAGridButton>,
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAAGridTemplate {
            val elementId = map["_elementId"] as? String ?: ""
            val title = map["title"] as? String ?: ""
            val buttons = (map["buttons"] as? List<*>)?.mapNotNull {
                (it as? Map<*, *>)?.mapKeys { entry -> entry.key.toString() }
                    ?.let { FAAGridButton.fromJson(it) }
            } ?: emptyList()

            return FAAGridTemplate(elementId, title, buttons)
        }
    }
}
