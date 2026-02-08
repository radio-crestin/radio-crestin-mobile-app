package com.oguzhnatly.flutter_android_auto

data class FAATabTemplate(
    val elementId: String,
    val tabs: List<FAATab>,
    val activeTabContentId: String,
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAATabTemplate {
            val elementId = map["_elementId"] as? String ?: ""
            val activeTabContentId = map["activeTabContentId"] as? String ?: ""
            val tabs = (map["tabs"] as? List<*>)?.mapNotNull {
                (it as? Map<*, *>)?.mapKeys { entry -> entry.key.toString() }
                    ?.let { FAATab.fromJson(it) }
            } ?: emptyList()

            return FAATabTemplate(elementId, tabs, activeTabContentId)
        }
    }
}
