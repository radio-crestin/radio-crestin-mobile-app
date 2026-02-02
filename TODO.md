-  fallback-ul nu functioneaza cand cade HLS-ul




----
- Highlight statia selectata in lista de optiuni - DONE
- Creaza o iconita pentru notificare - DONE
- adauga prioritate la notificarea audio - DONE (kind of)
-  Fixeaza butoanele de start si stop din notificare - DONE (kind of)
-  Adauga 3 surse audio cu fallback automat - DONE
-  Scoate HLS din Bunny - DONE
- Trimite date catre api-ul nostru cand se asculta prin proxy/HLS - DONE
- afiseaza numarul de ascultatori - DONE
- afiseaza cand o statie e down - DONE
- fixeaza bug-ul cu ordinea statiilor - DONE
- fa iconita patrata - DONE
- identifica de ce homepage-ul e alb cateodata - DONE
- fa splash screen-ul cu background-ul alb - DONE
-  Adauga optiune de a forta utilizatorul sa faca upgrade - DONE
   - eventual adauga si un buton pe care sa il afisam pentru a face upgrade
   - https://pub.dev/packages/upgrader
-  Testeaza flow-ul de notificari personalizate - DONE
- Afiseaza in-app notifications - DONE
-  Nu uita sa modifici link-ul de share din Firebase - DONE
-  Listeaza aplicatia in Play Store - DONE

Pe viitor:
- cand aplicatia este inchisa din task manager, opreste player-ul si request-urile de refresh metadata
- adauga deep links cu site-ul www.radio-crestin.com ca sa deschida aplicatia - DONE partial
- adauga optiune sa faci search la o statie
- listeaza aplicatia pe IOS - DONE
- listeaza aplicatia in Huawei Store
- listeaza aplicatia in Windows Store
- listeaza aplicatia in Amazon Store
- listeaza aplicatia in Android Auto
- listeaza aplicatia in Android TV
- listeaza aplicatia in Apple TV
- salveaza ultima statie redata si porneste cu respectiva statie
- adauga o optiune prin care marchezi statiile ca favorite si le adaugi intr-o lista separata


Universal LInks on Ios:
https://github.com/doch2/uni_links_nfc_support/tree/main/uni_links_nfc_support
https://pub.dev/packages/flutter_nfc_kit
adb shell 'am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "android-app://com.radiocrestin.radio_crestin/https/www.radiocrestin.ro/radio/rve-timisoara/?mobile=true"'
adb shell 'am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "https://play.google.com/store/apps/details?id=com.radiocrestin.radio_crestin&referrer=rve-timisoara"'

https://play.google.com/store/apps/details?id=com.radiocrestin.radio_crestin&url=radiocrestin%3A%2F%2Frve-timisoara
market://details?id=com.radiocrestin.radio_crestin&url=radiocrestin%3A%2F%2Frve-timisoara