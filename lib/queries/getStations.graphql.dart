import 'dart:async';

import 'package:flutter/widgets.dart' as widgets;
import 'package:gql/ast.dart';
import 'package:graphql/client.dart' as graphql;
import 'package:graphql_flutter/graphql_flutter.dart' as graphql_flutter;

class Query$GetStations {
  Query$GetStations({
    required this.stations,
    this.$__typename = 'query_root',
  });

  factory Query$GetStations.fromJson(Map<String, dynamic> json) {
    final l$stations = json['stations'];
    final l$$__typename = json['__typename'];
    return Query$GetStations(
      stations: (l$stations as List<dynamic>)
          .map((e) =>
          Query$GetStations$stations.fromJson((e as Map<String, dynamic>)))
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Query$GetStations$stations> stations;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$stations = stations;
    _resultData['stations'] = l$stations.map((e) => e.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$stations = stations;
    final l$$__typename = $__typename;
    return Object.hashAll([
      Object.hashAll(l$stations.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations) || runtimeType != other.runtimeType) {
      return false;
    }
    final l$stations = stations;
    final lOther$stations = other.stations;
    if (l$stations.length != lOther$stations.length) {
      return false;
    }
    for (int i = 0; i < l$stations.length; i++) {
      final l$stations$entry = l$stations[i];
      final lOther$stations$entry = lOther$stations[i];
      if (l$stations$entry != lOther$stations$entry) {
        return false;
      }
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations on Query$GetStations {
  CopyWith$Query$GetStations<Query$GetStations> get copyWith =>
      CopyWith$Query$GetStations(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations<TRes> {
  factory CopyWith$Query$GetStations(Query$GetStations instance,
      TRes Function(Query$GetStations) then,) = _CopyWithImpl$Query$GetStations;

  factory CopyWith$Query$GetStations.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations;

  TRes call({
    List<Query$GetStations$stations>? stations,
    String? $__typename,
  });

  TRes stations(Iterable<Query$GetStations$stations> Function(
      Iterable<
          CopyWith$Query$GetStations$stations<
              Query$GetStations$stations>>)
  _fn);
}

class _CopyWithImpl$Query$GetStations<TRes>
    implements CopyWith$Query$GetStations<TRes> {
  _CopyWithImpl$Query$GetStations(this._instance,
      this._then,);

  final Query$GetStations _instance;

  final TRes Function(Query$GetStations) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? stations = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations(
        stations: stations == _undefined || stations == null
            ? _instance.stations
            : (stations as List<Query$GetStations$stations>),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));

  TRes stations(Iterable<Query$GetStations$stations> Function(
      Iterable<
          CopyWith$Query$GetStations$stations<
              Query$GetStations$stations>>)
  _fn) =>
      call(
          stations: _fn(
              _instance.stations.map((e) =>
                  CopyWith$Query$GetStations$stations(
                    e,
                        (i) => i,
                  ))).toList());
}

class _CopyWithStubImpl$Query$GetStations<TRes>
    implements CopyWith$Query$GetStations<TRes> {
  _CopyWithStubImpl$Query$GetStations(this._res);

  TRes _res;

  call({
    List<Query$GetStations$stations>? stations,
    String? $__typename,
  }) =>
      _res;

  stations(_fn) => _res;
}

const documentNodeQueryGetStations = DocumentNode(definitions: [
  OperationDefinitionNode(
    type: OperationType.query,
    name: NameNode(value: 'GetStations'),
    variableDefinitions: [],
    directives: [],
    selectionSet: SelectionSetNode(selections: [
      FieldNode(
        name: NameNode(value: 'stations'),
        alias: null,
        arguments: [
          ArgumentNode(
            name: NameNode(value: 'order_by'),
            value: ObjectValueNode(fields: [
              ObjectFieldNode(
                name: NameNode(value: 'order'),
                value: EnumValueNode(name: NameNode(value: 'asc')),
              ),
              ObjectFieldNode(
                name: NameNode(value: 'title'),
                value: EnumValueNode(name: NameNode(value: 'asc')),
              ),
            ]),
          )
        ],
        directives: [],
        selectionSet: SelectionSetNode(selections: [
          FieldNode(
            name: NameNode(value: 'id'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'slug'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'order'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'title'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'website'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'email'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'stream_url'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'proxy_stream_url'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'hls_stream_url'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'thumbnail_url'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'total_listeners'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'description'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'description_action_title'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'description_link'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'feature_latest_post'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'facebook_page_id'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
          FieldNode(
            name: NameNode(value: 'posts'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'limit'),
                value: IntValueNode(value: '1'),
              ),
              ArgumentNode(
                name: NameNode(value: 'order_by'),
                value: ObjectValueNode(fields: [
                  ObjectFieldNode(
                    name: NameNode(value: 'published'),
                    value: EnumValueNode(name: NameNode(value: 'desc')),
                  )
                ]),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(selections: [
              FieldNode(
                name: NameNode(value: 'id'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'title'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'description'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'link'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'published'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: '__typename'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
            ]),
          ),
          FieldNode(
            name: NameNode(value: 'uptime'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: SelectionSetNode(selections: [
              FieldNode(
                name: NameNode(value: 'is_up'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'latency_ms'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'timestamp'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: '__typename'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
            ]),
          ),
          FieldNode(
            name: NameNode(value: 'now_playing'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: SelectionSetNode(selections: [
              FieldNode(
                name: NameNode(value: 'id'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'timestamp'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'song'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: SelectionSetNode(selections: [
                  FieldNode(
                    name: NameNode(value: 'id'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'name'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'thumbnail_url'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'artist'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: SelectionSetNode(selections: [
                      FieldNode(
                        name: NameNode(value: 'id'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'name'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'thumbnail_url'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: '__typename'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                    ]),
                  ),
                  FieldNode(
                    name: NameNode(value: '__typename'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                ]),
              ),
              FieldNode(
                name: NameNode(value: '__typename'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
            ]),
          ),
          FieldNode(
            name: NameNode(value: 'reviews'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: SelectionSetNode(selections: [
              FieldNode(
                name: NameNode(value: 'id'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'stars'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'message'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: '__typename'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
            ]),
          ),
          FieldNode(
            name: NameNode(value: '__typename'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
        ]),
      ),
      FieldNode(
        name: NameNode(value: '__typename'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
    ]),
  ),
]);

Query$GetStations _parserFn$Query$GetStations(Map<String, dynamic> data) =>
    Query$GetStations.fromJson(data);

typedef OnQueryComplete$Query$GetStations = FutureOr<void> Function(
    Map<String, dynamic>?,
    Query$GetStations?,
    );

class Options$Query$GetStations extends graphql.QueryOptions<Query$GetStations> {
  Options$Query$GetStations({
    String? operationName,
    graphql.FetchPolicy? fetchPolicy,
    graphql.ErrorPolicy? errorPolicy,
    graphql.CacheRereadPolicy? cacheRereadPolicy,
    Object? optimisticResult,
    Query$GetStations? typedOptimisticResult,
    Duration? pollInterval,
    graphql.Context? context,
    OnQueryComplete$Query$GetStations? onComplete,
    graphql.OnQueryError? onError,
  })
      : onCompleteWithParsed = onComplete,
        super(
        operationName: operationName,
        fetchPolicy: fetchPolicy,
        errorPolicy: errorPolicy,
        cacheRereadPolicy: cacheRereadPolicy,
        optimisticResult: optimisticResult ?? typedOptimisticResult?.toJson(),
        pollInterval: pollInterval,
        context: context,
        onComplete: onComplete == null
            ? null
            : (data) =>
            onComplete(
              data,
              data == null ? null : _parserFn$Query$GetStations(data),
            ),
        onError: onError,
        document: documentNodeQueryGetStations,
        parserFn: _parserFn$Query$GetStations,
      );

  final OnQueryComplete$Query$GetStations? onCompleteWithParsed;

  @override
  List<Object?> get properties =>
      [
        ...super.onComplete == null
            ? super.properties
            : super.properties.where((property) => property != onComplete),
        onCompleteWithParsed,
      ];
}

class WatchOptions$Query$GetStations extends graphql.WatchQueryOptions<Query$GetStations> {
  WatchOptions$Query$GetStations({
    String? operationName,
    graphql.FetchPolicy? fetchPolicy,
    graphql.ErrorPolicy? errorPolicy,
    graphql.CacheRereadPolicy? cacheRereadPolicy,
    Object? optimisticResult,
    Query$GetStations? typedOptimisticResult,
    graphql.Context? context,
    Duration? pollInterval,
    bool? eagerlyFetchResults,
    bool carryForwardDataOnException = true,
    bool fetchResults = false,
  }) : super(
    operationName: operationName,
    fetchPolicy: fetchPolicy,
    errorPolicy: errorPolicy,
    cacheRereadPolicy: cacheRereadPolicy,
    optimisticResult: optimisticResult ?? typedOptimisticResult?.toJson(),
    context: context,
    document: documentNodeQueryGetStations,
    pollInterval: pollInterval,
    eagerlyFetchResults: eagerlyFetchResults,
    carryForwardDataOnException: carryForwardDataOnException,
    fetchResults: fetchResults,
    parserFn: _parserFn$Query$GetStations,
  );
}

class FetchMoreOptions$Query$GetStations extends graphql.FetchMoreOptions {
  FetchMoreOptions$Query$GetStations({required graphql.UpdateQuery updateQuery})
      : super(
    updateQuery: updateQuery,
    document: documentNodeQueryGetStations,
  );
}

extension ClientExtension$Query$GetStations on graphql.GraphQLClient {
  Future<graphql.QueryResult<Query$GetStations>> query$GetStations(
      [Options$Query$GetStations? options]) async =>
      await this.query(options ?? Options$Query$GetStations());

  graphql.ObservableQuery<Query$GetStations> watchQuery$GetStations(
      [WatchOptions$Query$GetStations? options]) =>
      this.watchQuery(options ?? WatchOptions$Query$GetStations());

  void writeQuery$GetStations({
    required Query$GetStations data,
    bool broadcast = true,
  }) =>
      this.writeQuery(
        graphql.Request(
            operation:
            graphql.Operation(document: documentNodeQueryGetStations)),
        data: data.toJson(),
        broadcast: broadcast,
      );

  Query$GetStations? readQuery$GetStations({bool optimistic = true}) {
    final result = this.readQuery(
      graphql.Request(
          operation: graphql.Operation(document: documentNodeQueryGetStations)),
      optimistic: optimistic,
    );
    return result == null ? null : Query$GetStations.fromJson(result);
  }
}

graphql_flutter.QueryHookResult<Query$GetStations> useQuery$GetStations(
    [Options$Query$GetStations? options]) =>
    graphql_flutter.useQuery(options ?? Options$Query$GetStations());

graphql.ObservableQuery<Query$GetStations> useWatchQuery$GetStations(
    [WatchOptions$Query$GetStations? options]) =>
    graphql_flutter.useWatchQuery(options ?? WatchOptions$Query$GetStations());

class Query$GetStations$Widget extends graphql_flutter.Query<Query$GetStations> {
  Query$GetStations$Widget({
    widgets.Key? key,
    Options$Query$GetStations? options,
    required graphql_flutter.QueryBuilder<Query$GetStations> builder,
  }) : super(
    key: key,
    options: options ?? Options$Query$GetStations(),
    builder: builder,
  );
}

class Query$GetStations$stations {
  Query$GetStations$stations({
    required this.id,
    required this.slug,
    required this.order,
    required this.title,
    required this.website,
    required this.email,
    required this.stream_url,
    this.proxy_stream_url,
    this.hls_stream_url,
    this.thumbnail_url,
    this.total_listeners,
    this.description,
    this.description_action_title,
    this.description_link,
    required this.feature_latest_post,
    this.facebook_page_id,
    required this.posts,
    this.uptime,
    this.now_playing,
    required this.reviews,
    this.$__typename = 'stations',
  });

  factory Query$GetStations$stations.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$slug = json['slug'];
    final l$order = json['order'];
    final l$title = json['title'];
    final l$website = json['website'];
    final l$email = json['email'];
    final l$stream_url = json['stream_url'];
    final l$proxy_stream_url = json['proxy_stream_url'];
    final l$hls_stream_url = json['hls_stream_url'];
    final l$thumbnail_url = json['thumbnail_url'];
    final l$total_listeners = json['total_listeners'];
    final l$description = json['description'];
    final l$description_action_title = json['description_action_title'];
    final l$description_link = json['description_link'];
    final l$feature_latest_post = json['feature_latest_post'];
    final l$facebook_page_id = json['facebook_page_id'];
    final l$posts = json['posts'];
    final l$uptime = json['uptime'];
    final l$now_playing = json['now_playing'];
    final l$reviews = json['reviews'];
    final l$$__typename = json['__typename'];
    return Query$GetStations$stations(
      id: (l$id as int),
      slug: (l$slug as String),
      order: (l$order as int),
      title: (l$title as String),
      website: (l$website as String),
      email: (l$email as String),
      stream_url: (l$stream_url as String),
      proxy_stream_url: (l$proxy_stream_url as String?),
      hls_stream_url: (l$hls_stream_url as String?),
      thumbnail_url: (l$thumbnail_url as String?),
      total_listeners: (l$total_listeners as int?),
      description: (l$description as String?),
      description_action_title: (l$description_action_title as String?),
      description_link: (l$description_link as String?),
      feature_latest_post: (l$feature_latest_post as bool),
      facebook_page_id: (l$facebook_page_id as String?),
      posts: (l$posts as List<dynamic>)
          .map((e) =>
          Query$GetStations$stations$posts.fromJson(
              (e as Map<String, dynamic>)))
          .toList(),
      uptime: l$uptime == null
          ? null
          : Query$GetStations$stations$uptime.fromJson(
          (l$uptime as Map<String, dynamic>)),
      now_playing: l$now_playing == null
          ? null
          : Query$GetStations$stations$now_playing.fromJson(
          (l$now_playing as Map<String, dynamic>)),
      reviews: (l$reviews as List<dynamic>)
          .map((e) =>
          Query$GetStations$stations$reviews.fromJson(
              (e as Map<String, dynamic>)))
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final int id;

  final String slug;

  final int order;

  final String title;

  final String website;

  final String email;

  final String stream_url;

  final String? proxy_stream_url;

  final String? hls_stream_url;

  final String? thumbnail_url;

  final int? total_listeners;

  final String? description;

  final String? description_action_title;

  final String? description_link;

  final bool feature_latest_post;

  final String? facebook_page_id;

  final List<Query$GetStations$stations$posts> posts;

  final Query$GetStations$stations$uptime? uptime;

  final Query$GetStations$stations$now_playing? now_playing;

  final List<Query$GetStations$stations$reviews> reviews;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$slug = slug;
    _resultData['slug'] = l$slug;
    final l$order = order;
    _resultData['order'] = l$order;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$website = website;
    _resultData['website'] = l$website;
    final l$email = email;
    _resultData['email'] = l$email;
    final l$stream_url = stream_url;
    _resultData['stream_url'] = l$stream_url;
    final l$proxy_stream_url = proxy_stream_url;
    _resultData['proxy_stream_url'] = l$proxy_stream_url;
    final l$hls_stream_url = hls_stream_url;
    _resultData['hls_stream_url'] = l$hls_stream_url;
    final l$thumbnail_url = thumbnail_url;
    _resultData['thumbnail_url'] = l$thumbnail_url;
    final l$total_listeners = total_listeners;
    _resultData['total_listeners'] = l$total_listeners;
    final l$description = description;
    _resultData['description'] = l$description;
    final l$description_action_title = description_action_title;
    _resultData['description_action_title'] = l$description_action_title;
    final l$description_link = description_link;
    _resultData['description_link'] = l$description_link;
    final l$feature_latest_post = feature_latest_post;
    _resultData['feature_latest_post'] = l$feature_latest_post;
    final l$facebook_page_id = facebook_page_id;
    _resultData['facebook_page_id'] = l$facebook_page_id;
    final l$posts = posts;
    _resultData['posts'] = l$posts.map((e) => e.toJson()).toList();
    final l$uptime = uptime;
    _resultData['uptime'] = l$uptime?.toJson();
    final l$now_playing = now_playing;
    _resultData['now_playing'] = l$now_playing?.toJson();
    final l$reviews = reviews;
    _resultData['reviews'] = l$reviews.map((e) => e.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$slug = slug;
    final l$order = order;
    final l$title = title;
    final l$website = website;
    final l$email = email;
    final l$stream_url = stream_url;
    final l$proxy_stream_url = proxy_stream_url;
    final l$hls_stream_url = hls_stream_url;
    final l$thumbnail_url = thumbnail_url;
    final l$total_listeners = total_listeners;
    final l$description = description;
    final l$description_action_title = description_action_title;
    final l$description_link = description_link;
    final l$feature_latest_post = feature_latest_post;
    final l$facebook_page_id = facebook_page_id;
    final l$posts = posts;
    final l$uptime = uptime;
    final l$now_playing = now_playing;
    final l$reviews = reviews;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$slug,
      l$order,
      l$title,
      l$website,
      l$email,
      l$stream_url,
      l$proxy_stream_url,
      l$hls_stream_url,
      l$thumbnail_url,
      l$total_listeners,
      l$description,
      l$description_action_title,
      l$description_link,
      l$feature_latest_post,
      l$facebook_page_id,
      Object.hashAll(l$posts.map((v) => v)),
      l$uptime,
      l$now_playing,
      Object.hashAll(l$reviews.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations$stations) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$slug = slug;
    final lOther$slug = other.slug;
    if (l$slug != lOther$slug) {
      return false;
    }
    final l$order = order;
    final lOther$order = other.order;
    if (l$order != lOther$order) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$website = website;
    final lOther$website = other.website;
    if (l$website != lOther$website) {
      return false;
    }
    final l$email = email;
    final lOther$email = other.email;
    if (l$email != lOther$email) {
      return false;
    }
    final l$stream_url = stream_url;
    final lOther$stream_url = other.stream_url;
    if (l$stream_url != lOther$stream_url) {
      return false;
    }
    final l$proxy_stream_url = proxy_stream_url;
    final lOther$proxy_stream_url = other.proxy_stream_url;
    if (l$proxy_stream_url != lOther$proxy_stream_url) {
      return false;
    }
    final l$hls_stream_url = hls_stream_url;
    final lOther$hls_stream_url = other.hls_stream_url;
    if (l$hls_stream_url != lOther$hls_stream_url) {
      return false;
    }
    final l$thumbnail_url = thumbnail_url;
    final lOther$thumbnail_url = other.thumbnail_url;
    if (l$thumbnail_url != lOther$thumbnail_url) {
      return false;
    }
    final l$total_listeners = total_listeners;
    final lOther$total_listeners = other.total_listeners;
    if (l$total_listeners != lOther$total_listeners) {
      return false;
    }
    final l$description = description;
    final lOther$description = other.description;
    if (l$description != lOther$description) {
      return false;
    }
    final l$description_action_title = description_action_title;
    final lOther$description_action_title = other.description_action_title;
    if (l$description_action_title != lOther$description_action_title) {
      return false;
    }
    final l$description_link = description_link;
    final lOther$description_link = other.description_link;
    if (l$description_link != lOther$description_link) {
      return false;
    }
    final l$feature_latest_post = feature_latest_post;
    final lOther$feature_latest_post = other.feature_latest_post;
    if (l$feature_latest_post != lOther$feature_latest_post) {
      return false;
    }
    final l$facebook_page_id = facebook_page_id;
    final lOther$facebook_page_id = other.facebook_page_id;
    if (l$facebook_page_id != lOther$facebook_page_id) {
      return false;
    }
    final l$posts = posts;
    final lOther$posts = other.posts;
    if (l$posts.length != lOther$posts.length) {
      return false;
    }
    for (int i = 0; i < l$posts.length; i++) {
      final l$posts$entry = l$posts[i];
      final lOther$posts$entry = lOther$posts[i];
      if (l$posts$entry != lOther$posts$entry) {
        return false;
      }
    }
    final l$uptime = uptime;
    final lOther$uptime = other.uptime;
    if (l$uptime != lOther$uptime) {
      return false;
    }
    final l$now_playing = now_playing;
    final lOther$now_playing = other.now_playing;
    if (l$now_playing != lOther$now_playing) {
      return false;
    }
    final l$reviews = reviews;
    final lOther$reviews = other.reviews;
    if (l$reviews.length != lOther$reviews.length) {
      return false;
    }
    for (int i = 0; i < l$reviews.length; i++) {
      final l$reviews$entry = l$reviews[i];
      final lOther$reviews$entry = lOther$reviews[i];
      if (l$reviews$entry != lOther$reviews$entry) {
        return false;
      }
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations$stations
on Query$GetStations$stations {
  CopyWith$Query$GetStations$stations<Query$GetStations$stations>
  get copyWith =>
      CopyWith$Query$GetStations$stations(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations$stations<TRes> {
  factory CopyWith$Query$GetStations$stations(Query$GetStations$stations instance,
      TRes Function(Query$GetStations$stations) then,) = _CopyWithImpl$Query$GetStations$stations;

  factory CopyWith$Query$GetStations$stations.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations$stations;

  TRes call({
    int? id,
    String? slug,
    int? order,
    String? title,
    String? website,
    String? email,
    String? stream_url,
    String? proxy_stream_url,
    String? hls_stream_url,
    String? thumbnail_url,
    int? total_listeners,
    String? description,
    String? description_action_title,
    String? description_link,
    bool? feature_latest_post,
    String? facebook_page_id,
    List<Query$GetStations$stations$posts>? posts,
    Query$GetStations$stations$uptime? uptime,
    Query$GetStations$stations$now_playing? now_playing,
    List<Query$GetStations$stations$reviews>? reviews,
    String? $__typename,
  });

  TRes posts(Iterable<Query$GetStations$stations$posts> Function(
      Iterable<
          CopyWith$Query$GetStations$stations$posts<
              Query$GetStations$stations$posts>>)
  _fn);

  CopyWith$Query$GetStations$stations$uptime<TRes> get uptime;

  CopyWith$Query$GetStations$stations$now_playing<TRes> get now_playing;

  TRes reviews(Iterable<Query$GetStations$stations$reviews> Function(
      Iterable<
          CopyWith$Query$GetStations$stations$reviews<
              Query$GetStations$stations$reviews>>)
  _fn);
}

class _CopyWithImpl$Query$GetStations$stations<TRes>
    implements CopyWith$Query$GetStations$stations<TRes> {
  _CopyWithImpl$Query$GetStations$stations(this._instance,
      this._then,);

  final Query$GetStations$stations _instance;

  final TRes Function(Query$GetStations$stations) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? slug = _undefined,
    Object? order = _undefined,
    Object? title = _undefined,
    Object? website = _undefined,
    Object? email = _undefined,
    Object? stream_url = _undefined,
    Object? proxy_stream_url = _undefined,
    Object? hls_stream_url = _undefined,
    Object? thumbnail_url = _undefined,
    Object? total_listeners = _undefined,
    Object? description = _undefined,
    Object? description_action_title = _undefined,
    Object? description_link = _undefined,
    Object? feature_latest_post = _undefined,
    Object? facebook_page_id = _undefined,
    Object? posts = _undefined,
    Object? uptime = _undefined,
    Object? now_playing = _undefined,
    Object? reviews = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations$stations(
        id: id == _undefined || id == null ? _instance.id : (id as int),
        slug: slug == _undefined || slug == null
            ? _instance.slug
            : (slug as String),
        order: order == _undefined || order == null
            ? _instance.order
            : (order as int),
        title: title == _undefined || title == null
            ? _instance.title
            : (title as String),
        website: website == _undefined || website == null
            ? _instance.website
            : (website as String),
        email: email == _undefined || email == null
            ? _instance.email
            : (email as String),
        stream_url: stream_url == _undefined || stream_url == null
            ? _instance.stream_url
            : (stream_url as String),
        proxy_stream_url: proxy_stream_url == _undefined
            ? _instance.proxy_stream_url
            : (proxy_stream_url as String?),
        hls_stream_url: hls_stream_url == _undefined
            ? _instance.hls_stream_url
            : (hls_stream_url as String?),
        thumbnail_url: thumbnail_url == _undefined
            ? _instance.thumbnail_url
            : (thumbnail_url as String?),
        total_listeners: total_listeners == _undefined
            ? _instance.total_listeners
            : (total_listeners as int?),
        description: description == _undefined
            ? _instance.description
            : (description as String?),
        description_action_title: description_action_title == _undefined
            ? _instance.description_action_title
            : (description_action_title as String?),
        description_link: description_link == _undefined
            ? _instance.description_link
            : (description_link as String?),
        feature_latest_post:
        feature_latest_post == _undefined || feature_latest_post == null
            ? _instance.feature_latest_post
            : (feature_latest_post as bool),
        facebook_page_id: facebook_page_id == _undefined
            ? _instance.facebook_page_id
            : (facebook_page_id as String?),
        posts: posts == _undefined || posts == null
            ? _instance.posts
            : (posts as List<Query$GetStations$stations$posts>),
        uptime: uptime == _undefined
            ? _instance.uptime
            : (uptime as Query$GetStations$stations$uptime?),
        now_playing: now_playing == _undefined
            ? _instance.now_playing
            : (now_playing as Query$GetStations$stations$now_playing?),
        reviews: reviews == _undefined || reviews == null
            ? _instance.reviews
            : (reviews as List<Query$GetStations$stations$reviews>),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));

  TRes posts(Iterable<Query$GetStations$stations$posts> Function(
      Iterable<
          CopyWith$Query$GetStations$stations$posts<
              Query$GetStations$stations$posts>>)
  _fn) =>
      call(
          posts: _fn(_instance.posts
              .map((e) =>
              CopyWith$Query$GetStations$stations$posts(
                e,
                    (i) => i,
              ))).toList());

  CopyWith$Query$GetStations$stations$uptime<TRes> get uptime {
    final local$uptime = _instance.uptime;
    return local$uptime == null
        ? CopyWith$Query$GetStations$stations$uptime.stub(_then(_instance))
        : CopyWith$Query$GetStations$stations$uptime(
        local$uptime, (e) => call(uptime: e));
  }

  CopyWith$Query$GetStations$stations$now_playing<TRes> get now_playing {
    final local$now_playing = _instance.now_playing;
    return local$now_playing == null
        ? CopyWith$Query$GetStations$stations$now_playing.stub(_then(_instance))
        : CopyWith$Query$GetStations$stations$now_playing(
        local$now_playing, (e) => call(now_playing: e));
  }

  TRes reviews(Iterable<Query$GetStations$stations$reviews> Function(
      Iterable<
          CopyWith$Query$GetStations$stations$reviews<
              Query$GetStations$stations$reviews>>)
  _fn) =>
      call(
          reviews: _fn(_instance.reviews
              .map((e) =>
              CopyWith$Query$GetStations$stations$reviews(
                e,
                    (i) => i,
              ))).toList());
}

class _CopyWithStubImpl$Query$GetStations$stations<TRes>
    implements CopyWith$Query$GetStations$stations<TRes> {
  _CopyWithStubImpl$Query$GetStations$stations(this._res);

  TRes _res;

  call({
    int? id,
    String? slug,
    int? order,
    String? title,
    String? website,
    String? email,
    String? stream_url,
    String? proxy_stream_url,
    String? hls_stream_url,
    String? thumbnail_url,
    int? total_listeners,
    String? description,
    String? description_action_title,
    String? description_link,
    bool? feature_latest_post,
    String? facebook_page_id,
    List<Query$GetStations$stations$posts>? posts,
    Query$GetStations$stations$uptime? uptime,
    Query$GetStations$stations$now_playing? now_playing,
    List<Query$GetStations$stations$reviews>? reviews,
    String? $__typename,
  }) =>
      _res;

  posts(_fn) => _res;

  CopyWith$Query$GetStations$stations$uptime<TRes> get uptime =>
      CopyWith$Query$GetStations$stations$uptime.stub(_res);

  CopyWith$Query$GetStations$stations$now_playing<TRes> get now_playing =>
      CopyWith$Query$GetStations$stations$now_playing.stub(_res);

  reviews(_fn) => _res;
}

class Query$GetStations$stations$posts {
  Query$GetStations$stations$posts({
    required this.id,
    required this.title,
    required this.description,
    required this.link,
    required this.published,
    this.$__typename = 'posts',
  });

  factory Query$GetStations$stations$posts.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$description = json['description'];
    final l$link = json['link'];
    final l$published = json['published'];
    final l$$__typename = json['__typename'];
    return Query$GetStations$stations$posts(
      id: (l$id as int),
      title: (l$title as String),
      description: (l$description as String),
      link: (l$link as String),
      published: (l$published as String),
      $__typename: (l$$__typename as String),
    );
  }

  final int id;

  final String title;

  final String description;

  final String link;

  final String published;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$description = description;
    _resultData['description'] = l$description;
    final l$link = link;
    _resultData['link'] = l$link;
    final l$published = published;
    _resultData['published'] = l$published;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$description = description;
    final l$link = link;
    final l$published = published;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$title,
      l$description,
      l$link,
      l$published,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations$stations$posts) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$description = description;
    final lOther$description = other.description;
    if (l$description != lOther$description) {
      return false;
    }
    final l$link = link;
    final lOther$link = other.link;
    if (l$link != lOther$link) {
      return false;
    }
    final l$published = published;
    final lOther$published = other.published;
    if (l$published != lOther$published) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations$stations$posts
on Query$GetStations$stations$posts {
  CopyWith$Query$GetStations$stations$posts<Query$GetStations$stations$posts>
  get copyWith =>
      CopyWith$Query$GetStations$stations$posts(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations$stations$posts<TRes> {
  factory CopyWith$Query$GetStations$stations$posts(Query$GetStations$stations$posts instance,
      TRes Function(Query$GetStations$stations$posts) then,) = _CopyWithImpl$Query$GetStations$stations$posts;

  factory CopyWith$Query$GetStations$stations$posts.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations$stations$posts;

  TRes call({
    int? id,
    String? title,
    String? description,
    String? link,
    String? published,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$GetStations$stations$posts<TRes>
    implements CopyWith$Query$GetStations$stations$posts<TRes> {
  _CopyWithImpl$Query$GetStations$stations$posts(this._instance,
      this._then,);

  final Query$GetStations$stations$posts _instance;

  final TRes Function(Query$GetStations$stations$posts) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? description = _undefined,
    Object? link = _undefined,
    Object? published = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations$stations$posts(
        id: id == _undefined || id == null ? _instance.id : (id as int),
        title: title == _undefined || title == null
            ? _instance.title
            : (title as String),
        description: description == _undefined || description == null
            ? _instance.description
            : (description as String),
        link: link == _undefined || link == null
            ? _instance.link
            : (link as String),
        published: published == _undefined || published == null
            ? _instance.published
            : (published as String),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));
}

class _CopyWithStubImpl$Query$GetStations$stations$posts<TRes>
    implements CopyWith$Query$GetStations$stations$posts<TRes> {
  _CopyWithStubImpl$Query$GetStations$stations$posts(this._res);

  TRes _res;

  call({
    int? id,
    String? title,
    String? description,
    String? link,
    String? published,
    String? $__typename,
  }) =>
      _res;
}

class Query$GetStations$stations$uptime {
  Query$GetStations$stations$uptime({
    required this.is_up,
    required this.latency_ms,
    required this.timestamp,
    this.$__typename = 'stations_uptime',
  });

  factory Query$GetStations$stations$uptime.fromJson(Map<String, dynamic> json) {
    final l$is_up = json['is_up'];
    final l$latency_ms = json['latency_ms'];
    final l$timestamp = json['timestamp'];
    final l$$__typename = json['__typename'];
    return Query$GetStations$stations$uptime(
      is_up: (l$is_up as bool),
      latency_ms: (l$latency_ms as int),
      timestamp: (l$timestamp as String),
      $__typename: (l$$__typename as String),
    );
  }

  final bool is_up;

  final int latency_ms;

  final String timestamp;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$is_up = is_up;
    _resultData['is_up'] = l$is_up;
    final l$latency_ms = latency_ms;
    _resultData['latency_ms'] = l$latency_ms;
    final l$timestamp = timestamp;
    _resultData['timestamp'] = l$timestamp;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$is_up = is_up;
    final l$latency_ms = latency_ms;
    final l$timestamp = timestamp;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$is_up,
      l$latency_ms,
      l$timestamp,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations$stations$uptime) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$is_up = is_up;
    final lOther$is_up = other.is_up;
    if (l$is_up != lOther$is_up) {
      return false;
    }
    final l$latency_ms = latency_ms;
    final lOther$latency_ms = other.latency_ms;
    if (l$latency_ms != lOther$latency_ms) {
      return false;
    }
    final l$timestamp = timestamp;
    final lOther$timestamp = other.timestamp;
    if (l$timestamp != lOther$timestamp) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations$stations$uptime
on Query$GetStations$stations$uptime {
  CopyWith$Query$GetStations$stations$uptime<Query$GetStations$stations$uptime>
  get copyWith =>
      CopyWith$Query$GetStations$stations$uptime(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations$stations$uptime<TRes> {
  factory CopyWith$Query$GetStations$stations$uptime(Query$GetStations$stations$uptime instance,
      TRes Function(Query$GetStations$stations$uptime) then,) = _CopyWithImpl$Query$GetStations$stations$uptime;

  factory CopyWith$Query$GetStations$stations$uptime.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations$stations$uptime;

  TRes call({
    bool? is_up,
    int? latency_ms,
    String? timestamp,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$GetStations$stations$uptime<TRes>
    implements CopyWith$Query$GetStations$stations$uptime<TRes> {
  _CopyWithImpl$Query$GetStations$stations$uptime(this._instance,
      this._then,);

  final Query$GetStations$stations$uptime _instance;

  final TRes Function(Query$GetStations$stations$uptime) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? is_up = _undefined,
    Object? latency_ms = _undefined,
    Object? timestamp = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations$stations$uptime(
        is_up: is_up == _undefined || is_up == null
            ? _instance.is_up
            : (is_up as bool),
        latency_ms: latency_ms == _undefined || latency_ms == null
            ? _instance.latency_ms
            : (latency_ms as int),
        timestamp: timestamp == _undefined || timestamp == null
            ? _instance.timestamp
            : (timestamp as String),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));
}

class _CopyWithStubImpl$Query$GetStations$stations$uptime<TRes>
    implements CopyWith$Query$GetStations$stations$uptime<TRes> {
  _CopyWithStubImpl$Query$GetStations$stations$uptime(this._res);

  TRes _res;

  call({
    bool? is_up,
    int? latency_ms,
    String? timestamp,
    String? $__typename,
  }) =>
      _res;
}

class Query$GetStations$stations$now_playing {
  Query$GetStations$stations$now_playing({
    required this.id,
    required this.timestamp,
    this.song,
    this.$__typename = 'stations_now_playing',
  });

  factory Query$GetStations$stations$now_playing.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$timestamp = json['timestamp'];
    final l$song = json['song'];
    final l$$__typename = json['__typename'];
    return Query$GetStations$stations$now_playing(
      id: (l$id as int),
      timestamp: (l$timestamp as String),
      song: l$song == null
          ? null
          : Query$GetStations$stations$now_playing$song.fromJson(
          (l$song as Map<String, dynamic>)),
      $__typename: (l$$__typename as String),
    );
  }

  final int id;

  final String timestamp;

  final Query$GetStations$stations$now_playing$song? song;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$timestamp = timestamp;
    _resultData['timestamp'] = l$timestamp;
    final l$song = song;
    _resultData['song'] = l$song?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$timestamp = timestamp;
    final l$song = song;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$timestamp,
      l$song,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations$stations$now_playing) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$timestamp = timestamp;
    final lOther$timestamp = other.timestamp;
    if (l$timestamp != lOther$timestamp) {
      return false;
    }
    final l$song = song;
    final lOther$song = other.song;
    if (l$song != lOther$song) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations$stations$now_playing
on Query$GetStations$stations$now_playing {
  CopyWith$Query$GetStations$stations$now_playing<
      Query$GetStations$stations$now_playing>
  get copyWith =>
      CopyWith$Query$GetStations$stations$now_playing(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations$stations$now_playing<TRes> {
  factory CopyWith$Query$GetStations$stations$now_playing(
      Query$GetStations$stations$now_playing instance,
      TRes Function(Query$GetStations$stations$now_playing) then,) = _CopyWithImpl$Query$GetStations$stations$now_playing;

  factory CopyWith$Query$GetStations$stations$now_playing.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations$stations$now_playing;

  TRes call({
    int? id,
    String? timestamp,
    Query$GetStations$stations$now_playing$song? song,
    String? $__typename,
  });

  CopyWith$Query$GetStations$stations$now_playing$song<TRes> get song;
}

class _CopyWithImpl$Query$GetStations$stations$now_playing<TRes>
    implements CopyWith$Query$GetStations$stations$now_playing<TRes> {
  _CopyWithImpl$Query$GetStations$stations$now_playing(this._instance,
      this._then,);

  final Query$GetStations$stations$now_playing _instance;

  final TRes Function(Query$GetStations$stations$now_playing) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? timestamp = _undefined,
    Object? song = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations$stations$now_playing(
        id: id == _undefined || id == null ? _instance.id : (id as int),
        timestamp: timestamp == _undefined || timestamp == null
            ? _instance.timestamp
            : (timestamp as String),
        song: song == _undefined
            ? _instance.song
            : (song as Query$GetStations$stations$now_playing$song?),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));

  CopyWith$Query$GetStations$stations$now_playing$song<TRes> get song {
    final local$song = _instance.song;
    return local$song == null
        ? CopyWith$Query$GetStations$stations$now_playing$song.stub(
        _then(_instance))
        : CopyWith$Query$GetStations$stations$now_playing$song(
        local$song, (e) => call(song: e));
  }
}

class _CopyWithStubImpl$Query$GetStations$stations$now_playing<TRes>
    implements CopyWith$Query$GetStations$stations$now_playing<TRes> {
  _CopyWithStubImpl$Query$GetStations$stations$now_playing(this._res);

  TRes _res;

  call({
    int? id,
    String? timestamp,
    Query$GetStations$stations$now_playing$song? song,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Query$GetStations$stations$now_playing$song<TRes> get song =>
      CopyWith$Query$GetStations$stations$now_playing$song.stub(_res);
}

class Query$GetStations$stations$now_playing$song {
  Query$GetStations$stations$now_playing$song({
    required this.id,
    this.name,
    this.thumbnail_url,
    this.artist,
    this.$__typename = 'songs',
  });

  factory Query$GetStations$stations$now_playing$song.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$name = json['name'];
    final l$thumbnail_url = json['thumbnail_url'];
    final l$artist = json['artist'];
    final l$$__typename = json['__typename'];
    return Query$GetStations$stations$now_playing$song(
      id: (l$id as int),
      name: (l$name as String?),
      thumbnail_url: (l$thumbnail_url as String?),
      artist: l$artist == null
          ? null
          : Query$GetStations$stations$now_playing$song$artist.fromJson(
          (l$artist as Map<String, dynamic>)),
      $__typename: (l$$__typename as String),
    );
  }

  final int id;

  final String? name;

  final String? thumbnail_url;

  final Query$GetStations$stations$now_playing$song$artist? artist;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$name = name;
    _resultData['name'] = l$name;
    final l$thumbnail_url = thumbnail_url;
    _resultData['thumbnail_url'] = l$thumbnail_url;
    final l$artist = artist;
    _resultData['artist'] = l$artist?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$name = name;
    final l$thumbnail_url = thumbnail_url;
    final l$artist = artist;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$name,
      l$thumbnail_url,
      l$artist,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations$stations$now_playing$song) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$name = name;
    final lOther$name = other.name;
    if (l$name != lOther$name) {
      return false;
    }
    final l$thumbnail_url = thumbnail_url;
    final lOther$thumbnail_url = other.thumbnail_url;
    if (l$thumbnail_url != lOther$thumbnail_url) {
      return false;
    }
    final l$artist = artist;
    final lOther$artist = other.artist;
    if (l$artist != lOther$artist) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations$stations$now_playing$song
on Query$GetStations$stations$now_playing$song {
  CopyWith$Query$GetStations$stations$now_playing$song<
      Query$GetStations$stations$now_playing$song>
  get copyWith =>
      CopyWith$Query$GetStations$stations$now_playing$song(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations$stations$now_playing$song<TRes> {
  factory CopyWith$Query$GetStations$stations$now_playing$song(
      Query$GetStations$stations$now_playing$song instance,
      TRes Function(Query$GetStations$stations$now_playing$song) then,) = _CopyWithImpl$Query$GetStations$stations$now_playing$song;

  factory CopyWith$Query$GetStations$stations$now_playing$song.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations$stations$now_playing$song;

  TRes call({
    int? id,
    String? name,
    String? thumbnail_url,
    Query$GetStations$stations$now_playing$song$artist? artist,
    String? $__typename,
  });

  CopyWith$Query$GetStations$stations$now_playing$song$artist<TRes> get artist;
}

class _CopyWithImpl$Query$GetStations$stations$now_playing$song<TRes>
    implements CopyWith$Query$GetStations$stations$now_playing$song<TRes> {
  _CopyWithImpl$Query$GetStations$stations$now_playing$song(this._instance,
      this._then,);

  final Query$GetStations$stations$now_playing$song _instance;

  final TRes Function(Query$GetStations$stations$now_playing$song) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? name = _undefined,
    Object? thumbnail_url = _undefined,
    Object? artist = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations$stations$now_playing$song(
        id: id == _undefined || id == null ? _instance.id : (id as int),
        name: name == _undefined ? _instance.name : (name as String?),
        thumbnail_url: thumbnail_url == _undefined
            ? _instance.thumbnail_url
            : (thumbnail_url as String?),
        artist: artist == _undefined
            ? _instance.artist
            : (artist as Query$GetStations$stations$now_playing$song$artist?),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));

  CopyWith$Query$GetStations$stations$now_playing$song$artist<TRes> get artist {
    final local$artist = _instance.artist;
    return local$artist == null
        ? CopyWith$Query$GetStations$stations$now_playing$song$artist.stub(
        _then(_instance))
        : CopyWith$Query$GetStations$stations$now_playing$song$artist(
        local$artist, (e) => call(artist: e));
  }
}

class _CopyWithStubImpl$Query$GetStations$stations$now_playing$song<TRes>
    implements CopyWith$Query$GetStations$stations$now_playing$song<TRes> {
  _CopyWithStubImpl$Query$GetStations$stations$now_playing$song(this._res);

  TRes _res;

  call({
    int? id,
    String? name,
    String? thumbnail_url,
    Query$GetStations$stations$now_playing$song$artist? artist,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Query$GetStations$stations$now_playing$song$artist<TRes>
  get artist =>
      CopyWith$Query$GetStations$stations$now_playing$song$artist.stub(
          _res);
}

class Query$GetStations$stations$now_playing$song$artist {
  Query$GetStations$stations$now_playing$song$artist({
    required this.id,
    this.name,
    this.thumbnail_url,
    this.$__typename = 'artists',
  });

  factory Query$GetStations$stations$now_playing$song$artist.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$name = json['name'];
    final l$thumbnail_url = json['thumbnail_url'];
    final l$$__typename = json['__typename'];
    return Query$GetStations$stations$now_playing$song$artist(
      id: (l$id as int),
      name: (l$name as String?),
      thumbnail_url: (l$thumbnail_url as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final int id;

  final String? name;

  final String? thumbnail_url;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$name = name;
    _resultData['name'] = l$name;
    final l$thumbnail_url = thumbnail_url;
    _resultData['thumbnail_url'] = l$thumbnail_url;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$name = name;
    final l$thumbnail_url = thumbnail_url;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$name,
      l$thumbnail_url,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations$stations$now_playing$song$artist) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$name = name;
    final lOther$name = other.name;
    if (l$name != lOther$name) {
      return false;
    }
    final l$thumbnail_url = thumbnail_url;
    final lOther$thumbnail_url = other.thumbnail_url;
    if (l$thumbnail_url != lOther$thumbnail_url) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations$stations$now_playing$song$artist
on Query$GetStations$stations$now_playing$song$artist {
  CopyWith$Query$GetStations$stations$now_playing$song$artist<
      Query$GetStations$stations$now_playing$song$artist>
  get copyWith =>
      CopyWith$Query$GetStations$stations$now_playing$song$artist(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations$stations$now_playing$song$artist<
TRes> {
  factory CopyWith$Query$GetStations$stations$now_playing$song$artist(
      Query$GetStations$stations$now_playing$song$artist instance,
      TRes Function(Query$GetStations$stations$now_playing$song$artist) then,) = _CopyWithImpl$Query$GetStations$stations$now_playing$song$artist;

  factory CopyWith$Query$GetStations$stations$now_playing$song$artist.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations$stations$now_playing$song$artist;

  TRes call({
    int? id,
    String? name,
    String? thumbnail_url,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$GetStations$stations$now_playing$song$artist<TRes>
    implements
        CopyWith$Query$GetStations$stations$now_playing$song$artist<TRes> {
  _CopyWithImpl$Query$GetStations$stations$now_playing$song$artist(this._instance,
      this._then,);

  final Query$GetStations$stations$now_playing$song$artist _instance;

  final TRes Function(Query$GetStations$stations$now_playing$song$artist) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? name = _undefined,
    Object? thumbnail_url = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations$stations$now_playing$song$artist(
        id: id == _undefined || id == null ? _instance.id : (id as int),
        name: name == _undefined ? _instance.name : (name as String?),
        thumbnail_url: thumbnail_url == _undefined
            ? _instance.thumbnail_url
            : (thumbnail_url as String?),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));
}

class _CopyWithStubImpl$Query$GetStations$stations$now_playing$song$artist<TRes>
    implements
        CopyWith$Query$GetStations$stations$now_playing$song$artist<TRes> {
  _CopyWithStubImpl$Query$GetStations$stations$now_playing$song$artist(this._res);

  TRes _res;

  call({
    int? id,
    String? name,
    String? thumbnail_url,
    String? $__typename,
  }) =>
      _res;
}

class Query$GetStations$stations$reviews {
  Query$GetStations$stations$reviews({
    required this.id,
    required this.stars,
    this.message,
    this.$__typename = 'reviews',
  });

  factory Query$GetStations$stations$reviews.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$stars = json['stars'];
    final l$message = json['message'];
    final l$$__typename = json['__typename'];
    return Query$GetStations$stations$reviews(
      id: (l$id as int),
      stars: (l$stars as int),
      message: (l$message as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final int id;

  final int stars;

  final String? message;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$stars = stars;
    _resultData['stars'] = l$stars;
    final l$message = message;
    _resultData['message'] = l$message;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$stars = stars;
    final l$message = message;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$stars,
      l$message,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Query$GetStations$stations$reviews) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$stars = stars;
    final lOther$stars = other.stars;
    if (l$stars != lOther$stars) {
      return false;
    }
    final l$message = message;
    final lOther$message = other.message;
    if (l$message != lOther$message) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$GetStations$stations$reviews
on Query$GetStations$stations$reviews {
  CopyWith$Query$GetStations$stations$reviews<
      Query$GetStations$stations$reviews>
  get copyWith =>
      CopyWith$Query$GetStations$stations$reviews(
        this,
            (i) => i,
      );
}

abstract class CopyWith$Query$GetStations$stations$reviews<TRes> {
  factory CopyWith$Query$GetStations$stations$reviews(Query$GetStations$stations$reviews instance,
      TRes Function(Query$GetStations$stations$reviews) then,) = _CopyWithImpl$Query$GetStations$stations$reviews;

  factory CopyWith$Query$GetStations$stations$reviews.stub(TRes res) =
  _CopyWithStubImpl$Query$GetStations$stations$reviews;

  TRes call({
    int? id,
    int? stars,
    String? message,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$GetStations$stations$reviews<TRes>
    implements CopyWith$Query$GetStations$stations$reviews<TRes> {
  _CopyWithImpl$Query$GetStations$stations$reviews(this._instance,
      this._then,);

  final Query$GetStations$stations$reviews _instance;

  final TRes Function(Query$GetStations$stations$reviews) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? stars = _undefined,
    Object? message = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Query$GetStations$stations$reviews(
        id: id == _undefined || id == null ? _instance.id : (id as int),
        stars: stars == _undefined || stars == null
            ? _instance.stars
            : (stars as int),
        message:
        message == _undefined ? _instance.message : (message as String?),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));
}

class _CopyWithStubImpl$Query$GetStations$stations$reviews<TRes>
    implements CopyWith$Query$GetStations$stations$reviews<TRes> {
  _CopyWithStubImpl$Query$GetStations$stations$reviews(this._res);

  TRes _res;

  call({
    int? id,
    int? stars,
    String? message,
    String? $__typename,
  }) =>
      _res;
}
