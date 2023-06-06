install-deps:
	npm install -g get-graphql-schema

introspect-graphql:
	get-graphql-schema https://graphql.radio-crestin.com/v1/graphql > lib/schema.graphql

generate-graphql-types:
	dart run build_runner build

generate-launcher-icons:
	dart run flutter_launcher_icons


generate-new-play-store-keystore:
	keytool -genkey -v -keystore ~/radio-crestin-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload

