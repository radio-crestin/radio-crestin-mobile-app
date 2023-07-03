importScripts("https://www.gstatic.com/firebasejs/9.10.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/9.10.0/firebase-messaging-compat.js");

firebase.initializeApp({
    apiKey: 'AIzaSyAWv9nQiR1Zht3u8Zhg2uM_6SgVUUvmaqA',
    appId: '1:1067346595846:web:4ef8297918188b503e7387',
    messagingSenderId: '1067346595846',
    projectId: 'radio-crestin-aea7e',
    authDomain: 'radio-crestin-aea7e.firebaseapp.com',
    storageBucket: 'radio-crestin-aea7e.appspot.com',
    measurementId: 'G-MF5NVKRQ5E',
});
// Necessary to receive background messages:
const messaging = firebase.messaging();

// Optional:
messaging.onBackgroundMessage((m) => {
  console.log("onBackgroundMessage", m);
});