import '../schema.graphql.dart';
import 'dart:async';
import 'package:flutter/widgets.dart' as widgets;
import 'package:gql/ast.dart';
import 'package:graphql/client.dart' as graphql;
import 'package:graphql_flutter/graphql_flutter.dart' as graphql_flutter;

class Variables$Mutation$GetShareLink {
  factory Variables$Mutation$GetShareLink({required String anonymous_id}) =>
      Variables$Mutation$GetShareLink._({
        r'anonymous_id': anonymous_id,
      });

  Variables$Mutation$GetShareLink._(this._$data);

  factory Variables$Mutation$GetShareLink.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$anonymous_id = data['anonymous_id'];
    result$data['anonymous_id'] = (l$anonymous_id as String);
    return Variables$Mutation$GetShareLink._(result$data);
  }

  Map<String, dynamic> _$data;

  String get anonymous_id => (_$data['anonymous_id'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$anonymous_id = anonymous_id;
    result$data['anonymous_id'] = l$anonymous_id;
    return result$data;
  }

  CopyWith$Variables$Mutation$GetShareLink<Variables$Mutation$GetShareLink>
      get copyWith => CopyWith$Variables$Mutation$GetShareLink(
            this,
            (i) => i,
          );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Variables$Mutation$GetShareLink) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$anonymous_id = anonymous_id;
    final lOther$anonymous_id = other.anonymous_id;
    if (l$anonymous_id != lOther$anonymous_id) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$anonymous_id = anonymous_id;
    return Object.hashAll([l$anonymous_id]);
  }
}

abstract class CopyWith$Variables$Mutation$GetShareLink<TRes> {
  factory CopyWith$Variables$Mutation$GetShareLink(
    Variables$Mutation$GetShareLink instance,
    TRes Function(Variables$Mutation$GetShareLink) then,
  ) = _CopyWithImpl$Variables$Mutation$GetShareLink;

  factory CopyWith$Variables$Mutation$GetShareLink.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$GetShareLink;

  TRes call({String? anonymous_id});
}

class _CopyWithImpl$Variables$Mutation$GetShareLink<TRes>
    implements CopyWith$Variables$Mutation$GetShareLink<TRes> {
  _CopyWithImpl$Variables$Mutation$GetShareLink(
    this._instance,
    this._then,
  );

  final Variables$Mutation$GetShareLink _instance;

  final TRes Function(Variables$Mutation$GetShareLink) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? anonymous_id = _undefined}) =>
      _then(Variables$Mutation$GetShareLink._({
        ..._instance._$data,
        if (anonymous_id != _undefined && anonymous_id != null)
          'anonymous_id': (anonymous_id as String),
      }));
}

class _CopyWithStubImpl$Variables$Mutation$GetShareLink<TRes>
    implements CopyWith$Variables$Mutation$GetShareLink<TRes> {
  _CopyWithStubImpl$Variables$Mutation$GetShareLink(this._res);

  TRes _res;

  call({String? anonymous_id}) => _res;
}

class Mutation$GetShareLink {
  Mutation$GetShareLink({
    required this.get_share_link,
    this.$__typename = 'mutationRoot',
  });

  factory Mutation$GetShareLink.fromJson(Map<String, dynamic> json) {
    final l$get_share_link = json['get_share_link'];
    final l$$__typename = json['__typename'];
    return Mutation$GetShareLink(
      get_share_link: Mutation$GetShareLink$get_share_link.fromJson(
          (l$get_share_link as Map<String, dynamic>)),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$GetShareLink$get_share_link get_share_link;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$get_share_link = get_share_link;
    _resultData['get_share_link'] = l$get_share_link.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$get_share_link = get_share_link;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$get_share_link,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Mutation$GetShareLink) || runtimeType != other.runtimeType) {
      return false;
    }
    final l$get_share_link = get_share_link;
    final lOther$get_share_link = other.get_share_link;
    if (l$get_share_link != lOther$get_share_link) {
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

extension UtilityExtension$Mutation$GetShareLink on Mutation$GetShareLink {
  CopyWith$Mutation$GetShareLink<Mutation$GetShareLink> get copyWith =>
      CopyWith$Mutation$GetShareLink(
        this,
        (i) => i,
      );
}

abstract class CopyWith$Mutation$GetShareLink<TRes> {
  factory CopyWith$Mutation$GetShareLink(
    Mutation$GetShareLink instance,
    TRes Function(Mutation$GetShareLink) then,
  ) = _CopyWithImpl$Mutation$GetShareLink;

  factory CopyWith$Mutation$GetShareLink.stub(TRes res) =
      _CopyWithStubImpl$Mutation$GetShareLink;

  TRes call({
    Mutation$GetShareLink$get_share_link? get_share_link,
    String? $__typename,
  });
  CopyWith$Mutation$GetShareLink$get_share_link<TRes> get get_share_link;
}

class _CopyWithImpl$Mutation$GetShareLink<TRes>
    implements CopyWith$Mutation$GetShareLink<TRes> {
  _CopyWithImpl$Mutation$GetShareLink(
    this._instance,
    this._then,
  );

  final Mutation$GetShareLink _instance;

  final TRes Function(Mutation$GetShareLink) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? get_share_link = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Mutation$GetShareLink(
        get_share_link: get_share_link == _undefined || get_share_link == null
            ? _instance.get_share_link
            : (get_share_link as Mutation$GetShareLink$get_share_link),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));

  CopyWith$Mutation$GetShareLink$get_share_link<TRes> get get_share_link {
    final local$get_share_link = _instance.get_share_link;
    return CopyWith$Mutation$GetShareLink$get_share_link(
        local$get_share_link, (e) => call(get_share_link: e));
  }
}

class _CopyWithStubImpl$Mutation$GetShareLink<TRes>
    implements CopyWith$Mutation$GetShareLink<TRes> {
  _CopyWithStubImpl$Mutation$GetShareLink(this._res);

  TRes _res;

  call({
    Mutation$GetShareLink$get_share_link? get_share_link,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$GetShareLink$get_share_link<TRes> get get_share_link =>
      CopyWith$Mutation$GetShareLink$get_share_link.stub(_res);
}

const documentNodeMutationGetShareLink = DocumentNode(definitions: [
  OperationDefinitionNode(
    type: OperationType.mutation,
    name: NameNode(value: 'GetShareLink'),
    variableDefinitions: [
      VariableDefinitionNode(
        variable: VariableNode(name: NameNode(value: 'anonymous_id')),
        type: NamedTypeNode(
          name: NameNode(value: 'String'),
          isNonNull: true,
        ),
        defaultValue: DefaultValueNode(value: null),
        directives: [],
      )
    ],
    directives: [],
    selectionSet: SelectionSetNode(selections: [
      FieldNode(
        name: NameNode(value: 'get_share_link'),
        alias: null,
        arguments: [
          ArgumentNode(
            name: NameNode(value: 'anonymous_id'),
            value: VariableNode(name: NameNode(value: 'anonymous_id')),
          )
        ],
        directives: [],
        selectionSet: SelectionSetNode(selections: [
          InlineFragmentNode(
            typeCondition: TypeConditionNode(
                on: NamedTypeNode(
              name: NameNode(value: 'GetShareLinkResponse'),
              isNonNull: false,
            )),
            directives: [],
            selectionSet: SelectionSetNode(selections: [
              FieldNode(
                name: NameNode(value: 'anonymous_id'),
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
                name: NameNode(value: 'share_link'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: SelectionSetNode(selections: [
                  FieldNode(
                    name: NameNode(value: 'visit_count'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'url'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'share_id'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'created_at'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'share_message'),
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
                name: NameNode(value: 'share_section_message'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'success'),
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
          InlineFragmentNode(
            typeCondition: TypeConditionNode(
                on: NamedTypeNode(
              name: NameNode(value: 'OperationInfo'),
              isNonNull: false,
            )),
            directives: [],
            selectionSet: SelectionSetNode(selections: [
              FieldNode(
                name: NameNode(value: '__typename'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: null,
              ),
              FieldNode(
                name: NameNode(value: 'messages'),
                alias: null,
                arguments: [],
                directives: [],
                selectionSet: SelectionSetNode(selections: [
                  FieldNode(
                    name: NameNode(value: 'code'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'field'),
                    alias: null,
                    arguments: [],
                    directives: [],
                    selectionSet: null,
                  ),
                  FieldNode(
                    name: NameNode(value: 'kind'),
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
Mutation$GetShareLink _parserFn$Mutation$GetShareLink(
        Map<String, dynamic> data) =>
    Mutation$GetShareLink.fromJson(data);
typedef OnMutationCompleted$Mutation$GetShareLink = FutureOr<void> Function(
  Map<String, dynamic>?,
  Mutation$GetShareLink?,
);

class Options$Mutation$GetShareLink
    extends graphql.MutationOptions<Mutation$GetShareLink> {
  Options$Mutation$GetShareLink({
    String? operationName,
    required Variables$Mutation$GetShareLink variables,
    graphql.FetchPolicy? fetchPolicy,
    graphql.ErrorPolicy? errorPolicy,
    graphql.CacheRereadPolicy? cacheRereadPolicy,
    Object? optimisticResult,
    Mutation$GetShareLink? typedOptimisticResult,
    graphql.Context? context,
    OnMutationCompleted$Mutation$GetShareLink? onCompleted,
    graphql.OnMutationUpdate<Mutation$GetShareLink>? update,
    graphql.OnError? onError,
  })  : onCompletedWithParsed = onCompleted,
        super(
          variables: variables.toJson(),
          operationName: operationName,
          fetchPolicy: fetchPolicy,
          errorPolicy: errorPolicy,
          cacheRereadPolicy: cacheRereadPolicy,
          optimisticResult: optimisticResult ?? typedOptimisticResult?.toJson(),
          context: context,
          onCompleted: onCompleted == null
              ? null
              : (data) => onCompleted(
                    data,
                    data == null ? null : _parserFn$Mutation$GetShareLink(data),
                  ),
          update: update,
          onError: onError,
          document: documentNodeMutationGetShareLink,
          parserFn: _parserFn$Mutation$GetShareLink,
        );

  final OnMutationCompleted$Mutation$GetShareLink? onCompletedWithParsed;

  @override
  List<Object?> get properties => [
        ...super.onCompleted == null
            ? super.properties
            : super.properties.where((property) => property != onCompleted),
        onCompletedWithParsed,
      ];
}

class WatchOptions$Mutation$GetShareLink
    extends graphql.WatchQueryOptions<Mutation$GetShareLink> {
  WatchOptions$Mutation$GetShareLink({
    String? operationName,
    required Variables$Mutation$GetShareLink variables,
    graphql.FetchPolicy? fetchPolicy,
    graphql.ErrorPolicy? errorPolicy,
    graphql.CacheRereadPolicy? cacheRereadPolicy,
    Object? optimisticResult,
    Mutation$GetShareLink? typedOptimisticResult,
    graphql.Context? context,
    Duration? pollInterval,
    bool? eagerlyFetchResults,
    bool carryForwardDataOnException = true,
    bool fetchResults = false,
  }) : super(
          variables: variables.toJson(),
          operationName: operationName,
          fetchPolicy: fetchPolicy,
          errorPolicy: errorPolicy,
          cacheRereadPolicy: cacheRereadPolicy,
          optimisticResult: optimisticResult ?? typedOptimisticResult?.toJson(),
          context: context,
          document: documentNodeMutationGetShareLink,
          pollInterval: pollInterval,
          eagerlyFetchResults: eagerlyFetchResults,
          carryForwardDataOnException: carryForwardDataOnException,
          fetchResults: fetchResults,
          parserFn: _parserFn$Mutation$GetShareLink,
        );
}

extension ClientExtension$Mutation$GetShareLink on graphql.GraphQLClient {
  Future<graphql.QueryResult<Mutation$GetShareLink>> mutate$GetShareLink(
          Options$Mutation$GetShareLink options) async =>
      await this.mutate(options);
  graphql.ObservableQuery<Mutation$GetShareLink> watchMutation$GetShareLink(
          WatchOptions$Mutation$GetShareLink options) =>
      this.watchMutation(options);
}

class Mutation$GetShareLink$HookResult {
  Mutation$GetShareLink$HookResult(
    this.runMutation,
    this.result,
  );

  final RunMutation$Mutation$GetShareLink runMutation;

  final graphql.QueryResult<Mutation$GetShareLink> result;
}

Mutation$GetShareLink$HookResult useMutation$GetShareLink(
    [WidgetOptions$Mutation$GetShareLink? options]) {
  final result = graphql_flutter
      .useMutation(options ?? WidgetOptions$Mutation$GetShareLink());
  return Mutation$GetShareLink$HookResult(
    (variables, {optimisticResult, typedOptimisticResult}) =>
        result.runMutation(
      variables.toJson(),
      optimisticResult: optimisticResult ?? typedOptimisticResult?.toJson(),
    ),
    result.result,
  );
}

graphql.ObservableQuery<Mutation$GetShareLink> useWatchMutation$GetShareLink(
        WatchOptions$Mutation$GetShareLink options) =>
    graphql_flutter.useWatchMutation(options);

class WidgetOptions$Mutation$GetShareLink
    extends graphql.MutationOptions<Mutation$GetShareLink> {
  WidgetOptions$Mutation$GetShareLink({
    String? operationName,
    graphql.FetchPolicy? fetchPolicy,
    graphql.ErrorPolicy? errorPolicy,
    graphql.CacheRereadPolicy? cacheRereadPolicy,
    Object? optimisticResult,
    Mutation$GetShareLink? typedOptimisticResult,
    graphql.Context? context,
    OnMutationCompleted$Mutation$GetShareLink? onCompleted,
    graphql.OnMutationUpdate<Mutation$GetShareLink>? update,
    graphql.OnError? onError,
  })  : onCompletedWithParsed = onCompleted,
        super(
          operationName: operationName,
          fetchPolicy: fetchPolicy,
          errorPolicy: errorPolicy,
          cacheRereadPolicy: cacheRereadPolicy,
          optimisticResult: optimisticResult ?? typedOptimisticResult?.toJson(),
          context: context,
          onCompleted: onCompleted == null
              ? null
              : (data) => onCompleted(
                    data,
                    data == null ? null : _parserFn$Mutation$GetShareLink(data),
                  ),
          update: update,
          onError: onError,
          document: documentNodeMutationGetShareLink,
          parserFn: _parserFn$Mutation$GetShareLink,
        );

  final OnMutationCompleted$Mutation$GetShareLink? onCompletedWithParsed;

  @override
  List<Object?> get properties => [
        ...super.onCompleted == null
            ? super.properties
            : super.properties.where((property) => property != onCompleted),
        onCompletedWithParsed,
      ];
}

typedef RunMutation$Mutation$GetShareLink
    = graphql.MultiSourceResult<Mutation$GetShareLink> Function(
  Variables$Mutation$GetShareLink, {
  Object? optimisticResult,
  Mutation$GetShareLink? typedOptimisticResult,
});
typedef Builder$Mutation$GetShareLink = widgets.Widget Function(
  RunMutation$Mutation$GetShareLink,
  graphql.QueryResult<Mutation$GetShareLink>?,
);

class Mutation$GetShareLink$Widget
    extends graphql_flutter.Mutation<Mutation$GetShareLink> {
  Mutation$GetShareLink$Widget({
    widgets.Key? key,
    WidgetOptions$Mutation$GetShareLink? options,
    required Builder$Mutation$GetShareLink builder,
  }) : super(
          key: key,
          options: options ?? WidgetOptions$Mutation$GetShareLink(),
          builder: (
            run,
            result,
          ) =>
              builder(
            (
              variables, {
              optimisticResult,
              typedOptimisticResult,
            }) =>
                run(
              variables.toJson(),
              optimisticResult:
                  optimisticResult ?? typedOptimisticResult?.toJson(),
            ),
            result,
          ),
        );
}

class Mutation$GetShareLink$get_share_link {
  Mutation$GetShareLink$get_share_link({required this.$__typename});

  factory Mutation$GetShareLink$get_share_link.fromJson(
      Map<String, dynamic> json) {
    switch (json["__typename"] as String) {
      case "GetShareLinkResponse":
        return Mutation$GetShareLink$get_share_link$$GetShareLinkResponse
            .fromJson(json);

      case "OperationInfo":
        return Mutation$GetShareLink$get_share_link$$OperationInfo.fromJson(
            json);

      default:
        final l$$__typename = json['__typename'];
        return Mutation$GetShareLink$get_share_link(
            $__typename: (l$$__typename as String));
    }
  }

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$$__typename = $__typename;
    return Object.hashAll([l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Mutation$GetShareLink$get_share_link) ||
        runtimeType != other.runtimeType) {
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

extension UtilityExtension$Mutation$GetShareLink$get_share_link
    on Mutation$GetShareLink$get_share_link {
  CopyWith$Mutation$GetShareLink$get_share_link<
          Mutation$GetShareLink$get_share_link>
      get copyWith => CopyWith$Mutation$GetShareLink$get_share_link(
            this,
            (i) => i,
          );
  _T when<_T>({
    required _T Function(
            Mutation$GetShareLink$get_share_link$$GetShareLinkResponse)
        getShareLinkResponse,
    required _T Function(Mutation$GetShareLink$get_share_link$$OperationInfo)
        operationInfo,
    required _T Function() orElse,
  }) {
    switch ($__typename) {
      case "GetShareLinkResponse":
        return getShareLinkResponse(
            this as Mutation$GetShareLink$get_share_link$$GetShareLinkResponse);

      case "OperationInfo":
        return operationInfo(
            this as Mutation$GetShareLink$get_share_link$$OperationInfo);

      default:
        return orElse();
    }
  }

  _T maybeWhen<_T>({
    _T Function(Mutation$GetShareLink$get_share_link$$GetShareLinkResponse)?
        getShareLinkResponse,
    _T Function(Mutation$GetShareLink$get_share_link$$OperationInfo)?
        operationInfo,
    required _T Function() orElse,
  }) {
    switch ($__typename) {
      case "GetShareLinkResponse":
        if (getShareLinkResponse != null) {
          return getShareLinkResponse(this
              as Mutation$GetShareLink$get_share_link$$GetShareLinkResponse);
        } else {
          return orElse();
        }

      case "OperationInfo":
        if (operationInfo != null) {
          return operationInfo(
              this as Mutation$GetShareLink$get_share_link$$OperationInfo);
        } else {
          return orElse();
        }

      default:
        return orElse();
    }
  }
}

abstract class CopyWith$Mutation$GetShareLink$get_share_link<TRes> {
  factory CopyWith$Mutation$GetShareLink$get_share_link(
    Mutation$GetShareLink$get_share_link instance,
    TRes Function(Mutation$GetShareLink$get_share_link) then,
  ) = _CopyWithImpl$Mutation$GetShareLink$get_share_link;

  factory CopyWith$Mutation$GetShareLink$get_share_link.stub(TRes res) =
      _CopyWithStubImpl$Mutation$GetShareLink$get_share_link;

  TRes call({String? $__typename});
}

class _CopyWithImpl$Mutation$GetShareLink$get_share_link<TRes>
    implements CopyWith$Mutation$GetShareLink$get_share_link<TRes> {
  _CopyWithImpl$Mutation$GetShareLink$get_share_link(
    this._instance,
    this._then,
  );

  final Mutation$GetShareLink$get_share_link _instance;

  final TRes Function(Mutation$GetShareLink$get_share_link) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? $__typename = _undefined}) =>
      _then(Mutation$GetShareLink$get_share_link(
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String)));
}

class _CopyWithStubImpl$Mutation$GetShareLink$get_share_link<TRes>
    implements CopyWith$Mutation$GetShareLink$get_share_link<TRes> {
  _CopyWithStubImpl$Mutation$GetShareLink$get_share_link(this._res);

  TRes _res;

  call({String? $__typename}) => _res;
}

class Mutation$GetShareLink$get_share_link$$GetShareLinkResponse
    implements Mutation$GetShareLink$get_share_link {
  Mutation$GetShareLink$get_share_link$$GetShareLinkResponse({
    this.anonymous_id,
    required this.message,
    this.share_link,
    this.share_section_message,
    required this.success,
    this.$__typename = 'GetShareLinkResponse',
  });

  factory Mutation$GetShareLink$get_share_link$$GetShareLinkResponse.fromJson(
      Map<String, dynamic> json) {
    final l$anonymous_id = json['anonymous_id'];
    final l$message = json['message'];
    final l$share_link = json['share_link'];
    final l$share_section_message = json['share_section_message'];
    final l$success = json['success'];
    final l$$__typename = json['__typename'];
    return Mutation$GetShareLink$get_share_link$$GetShareLinkResponse(
      anonymous_id: (l$anonymous_id as String?),
      message: (l$message as String),
      share_link: l$share_link == null
          ? null
          : Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link
              .fromJson((l$share_link as Map<String, dynamic>)),
      share_section_message: (l$share_section_message as String?),
      success: (l$success as bool),
      $__typename: (l$$__typename as String),
    );
  }

  final String? anonymous_id;

  final String message;

  final Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link?
      share_link;

  final String? share_section_message;

  final bool success;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$anonymous_id = anonymous_id;
    _resultData['anonymous_id'] = l$anonymous_id;
    final l$message = message;
    _resultData['message'] = l$message;
    final l$share_link = share_link;
    _resultData['share_link'] = l$share_link?.toJson();
    final l$share_section_message = share_section_message;
    _resultData['share_section_message'] = l$share_section_message;
    final l$success = success;
    _resultData['success'] = l$success;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$anonymous_id = anonymous_id;
    final l$message = message;
    final l$share_link = share_link;
    final l$share_section_message = share_section_message;
    final l$success = success;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$anonymous_id,
      l$message,
      l$share_link,
      l$share_section_message,
      l$success,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other
            is Mutation$GetShareLink$get_share_link$$GetShareLinkResponse) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$anonymous_id = anonymous_id;
    final lOther$anonymous_id = other.anonymous_id;
    if (l$anonymous_id != lOther$anonymous_id) {
      return false;
    }
    final l$message = message;
    final lOther$message = other.message;
    if (l$message != lOther$message) {
      return false;
    }
    final l$share_link = share_link;
    final lOther$share_link = other.share_link;
    if (l$share_link != lOther$share_link) {
      return false;
    }
    final l$share_section_message = share_section_message;
    final lOther$share_section_message = other.share_section_message;
    if (l$share_section_message != lOther$share_section_message) {
      return false;
    }
    final l$success = success;
    final lOther$success = other.success;
    if (l$success != lOther$success) {
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

extension UtilityExtension$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse
    on Mutation$GetShareLink$get_share_link$$GetShareLinkResponse {
  CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse<
          Mutation$GetShareLink$get_share_link$$GetShareLinkResponse>
      get copyWith =>
          CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse<
    TRes> {
  factory CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse(
    Mutation$GetShareLink$get_share_link$$GetShareLinkResponse instance,
    TRes Function(Mutation$GetShareLink$get_share_link$$GetShareLinkResponse)
        then,
  ) = _CopyWithImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse;

  factory CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse.stub(
          TRes res) =
      _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse;

  TRes call({
    String? anonymous_id,
    String? message,
    Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link?
        share_link,
    String? share_section_message,
    bool? success,
    String? $__typename,
  });
  CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
      TRes> get share_link;
}

class _CopyWithImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse<
        TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse<
            TRes> {
  _CopyWithImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse(
    this._instance,
    this._then,
  );

  final Mutation$GetShareLink$get_share_link$$GetShareLinkResponse _instance;

  final TRes Function(
      Mutation$GetShareLink$get_share_link$$GetShareLinkResponse) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? anonymous_id = _undefined,
    Object? message = _undefined,
    Object? share_link = _undefined,
    Object? share_section_message = _undefined,
    Object? success = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Mutation$GetShareLink$get_share_link$$GetShareLinkResponse(
        anonymous_id: anonymous_id == _undefined
            ? _instance.anonymous_id
            : (anonymous_id as String?),
        message: message == _undefined || message == null
            ? _instance.message
            : (message as String),
        share_link: share_link == _undefined
            ? _instance.share_link
            : (share_link
                as Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link?),
        share_section_message: share_section_message == _undefined
            ? _instance.share_section_message
            : (share_section_message as String?),
        success: success == _undefined || success == null
            ? _instance.success
            : (success as bool),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));

  CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
      TRes> get share_link {
    final local$share_link = _instance.share_link;
    return local$share_link == null
        ? CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link
            .stub(_then(_instance))
        : CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link(
            local$share_link, (e) => call(share_link: e));
  }
}

class _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse<
        TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse<
            TRes> {
  _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse(
      this._res);

  TRes _res;

  call({
    String? anonymous_id,
    String? message,
    Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link?
        share_link,
    String? share_section_message,
    bool? success,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
          TRes>
      get share_link =>
          CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link
              .stub(_res);
}

class Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link {
  Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link({
    required this.visit_count,
    required this.url,
    required this.share_id,
    required this.created_at,
    required this.share_message,
    this.$__typename = 'ShareLinkData',
  });

  factory Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link.fromJson(
      Map<String, dynamic> json) {
    final l$visit_count = json['visit_count'];
    final l$url = json['url'];
    final l$share_id = json['share_id'];
    final l$created_at = json['created_at'];
    final l$share_message = json['share_message'];
    final l$$__typename = json['__typename'];
    return Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link(
      visit_count: (l$visit_count as int),
      url: (l$url as String),
      share_id: (l$share_id as String),
      created_at: (l$created_at as String),
      share_message: (l$share_message as String),
      $__typename: (l$$__typename as String),
    );
  }

  final int visit_count;

  final String url;

  final String share_id;

  final String created_at;

  final String share_message;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$visit_count = visit_count;
    _resultData['visit_count'] = l$visit_count;
    final l$url = url;
    _resultData['url'] = l$url;
    final l$share_id = share_id;
    _resultData['share_id'] = l$share_id;
    final l$created_at = created_at;
    _resultData['created_at'] = l$created_at;
    final l$share_message = share_message;
    _resultData['share_message'] = l$share_message;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$visit_count = visit_count;
    final l$url = url;
    final l$share_id = share_id;
    final l$created_at = created_at;
    final l$share_message = share_message;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$visit_count,
      l$url,
      l$share_id,
      l$created_at,
      l$share_message,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other
            is Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$visit_count = visit_count;
    final lOther$visit_count = other.visit_count;
    if (l$visit_count != lOther$visit_count) {
      return false;
    }
    final l$url = url;
    final lOther$url = other.url;
    if (l$url != lOther$url) {
      return false;
    }
    final l$share_id = share_id;
    final lOther$share_id = other.share_id;
    if (l$share_id != lOther$share_id) {
      return false;
    }
    final l$created_at = created_at;
    final lOther$created_at = other.created_at;
    if (l$created_at != lOther$created_at) {
      return false;
    }
    final l$share_message = share_message;
    final lOther$share_message = other.share_message;
    if (l$share_message != lOther$share_message) {
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

extension UtilityExtension$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link
    on Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link {
  CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
          Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link>
      get copyWith =>
          CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
    TRes> {
  factory CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link(
    Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link
        instance,
    TRes Function(
            Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link)
        then,
  ) = _CopyWithImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link;

  factory CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link.stub(
          TRes res) =
      _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link;

  TRes call({
    int? visit_count,
    String? url,
    String? share_id,
    String? created_at,
    String? share_message,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
        TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
            TRes> {
  _CopyWithImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link(
    this._instance,
    this._then,
  );

  final Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link
      _instance;

  final TRes Function(
          Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link)
      _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? visit_count = _undefined,
    Object? url = _undefined,
    Object? share_id = _undefined,
    Object? created_at = _undefined,
    Object? share_message = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
          Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link(
        visit_count: visit_count == _undefined || visit_count == null
            ? _instance.visit_count
            : (visit_count as int),
        url: url == _undefined || url == null ? _instance.url : (url as String),
        share_id: share_id == _undefined || share_id == null
            ? _instance.share_id
            : (share_id as String),
        created_at: created_at == _undefined || created_at == null
            ? _instance.created_at
            : (created_at as String),
        share_message: share_message == _undefined || share_message == null
            ? _instance.share_message
            : (share_message as String),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));
}

class _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
        TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link<
            TRes> {
  _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$GetShareLinkResponse$share_link(
      this._res);

  TRes _res;

  call({
    int? visit_count,
    String? url,
    String? share_id,
    String? created_at,
    String? share_message,
    String? $__typename,
  }) =>
      _res;
}

class Mutation$GetShareLink$get_share_link$$OperationInfo
    implements Mutation$GetShareLink$get_share_link {
  Mutation$GetShareLink$get_share_link$$OperationInfo({
    this.$__typename = 'OperationInfo',
    required this.messages,
  });

  factory Mutation$GetShareLink$get_share_link$$OperationInfo.fromJson(
      Map<String, dynamic> json) {
    final l$$__typename = json['__typename'];
    final l$messages = json['messages'];
    return Mutation$GetShareLink$get_share_link$$OperationInfo(
      $__typename: (l$$__typename as String),
      messages: (l$messages as List<dynamic>)
          .map((e) =>
              Mutation$GetShareLink$get_share_link$$OperationInfo$messages
                  .fromJson((e as Map<String, dynamic>)))
          .toList(),
    );
  }

  final String $__typename;

  final List<Mutation$GetShareLink$get_share_link$$OperationInfo$messages>
      messages;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    final l$messages = messages;
    _resultData['messages'] = l$messages.map((e) => e.toJson()).toList();
    return _resultData;
  }

  @override
  int get hashCode {
    final l$$__typename = $__typename;
    final l$messages = messages;
    return Object.hashAll([
      l$$__typename,
      Object.hashAll(l$messages.map((v) => v)),
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other is Mutation$GetShareLink$get_share_link$$OperationInfo) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    final l$messages = messages;
    final lOther$messages = other.messages;
    if (l$messages.length != lOther$messages.length) {
      return false;
    }
    for (int i = 0; i < l$messages.length; i++) {
      final l$messages$entry = l$messages[i];
      final lOther$messages$entry = lOther$messages[i];
      if (l$messages$entry != lOther$messages$entry) {
        return false;
      }
    }
    return true;
  }
}

extension UtilityExtension$Mutation$GetShareLink$get_share_link$$OperationInfo
    on Mutation$GetShareLink$get_share_link$$OperationInfo {
  CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo<
          Mutation$GetShareLink$get_share_link$$OperationInfo>
      get copyWith =>
          CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo<
    TRes> {
  factory CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo(
    Mutation$GetShareLink$get_share_link$$OperationInfo instance,
    TRes Function(Mutation$GetShareLink$get_share_link$$OperationInfo) then,
  ) = _CopyWithImpl$Mutation$GetShareLink$get_share_link$$OperationInfo;

  factory CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo.stub(
          TRes res) =
      _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$OperationInfo;

  TRes call({
    String? $__typename,
    List<Mutation$GetShareLink$get_share_link$$OperationInfo$messages>?
        messages,
  });
  TRes messages(
      Iterable<Mutation$GetShareLink$get_share_link$$OperationInfo$messages> Function(
              Iterable<
                  CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
                      Mutation$GetShareLink$get_share_link$$OperationInfo$messages>>)
          _fn);
}

class _CopyWithImpl$Mutation$GetShareLink$get_share_link$$OperationInfo<TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo<TRes> {
  _CopyWithImpl$Mutation$GetShareLink$get_share_link$$OperationInfo(
    this._instance,
    this._then,
  );

  final Mutation$GetShareLink$get_share_link$$OperationInfo _instance;

  final TRes Function(Mutation$GetShareLink$get_share_link$$OperationInfo)
      _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? $__typename = _undefined,
    Object? messages = _undefined,
  }) =>
      _then(Mutation$GetShareLink$get_share_link$$OperationInfo(
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
        messages: messages == _undefined || messages == null
            ? _instance.messages
            : (messages as List<
                Mutation$GetShareLink$get_share_link$$OperationInfo$messages>),
      ));

  TRes messages(
          Iterable<Mutation$GetShareLink$get_share_link$$OperationInfo$messages> Function(
                  Iterable<
                      CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
                          Mutation$GetShareLink$get_share_link$$OperationInfo$messages>>)
              _fn) =>
      call(
          messages: _fn(_instance.messages.map((e) =>
              CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages(
                e,
                (i) => i,
              ))).toList());
}

class _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$OperationInfo<
        TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo<TRes> {
  _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$OperationInfo(
      this._res);

  TRes _res;

  call({
    String? $__typename,
    List<Mutation$GetShareLink$get_share_link$$OperationInfo$messages>?
        messages,
  }) =>
      _res;

  messages(_fn) => _res;
}

class Mutation$GetShareLink$get_share_link$$OperationInfo$messages {
  Mutation$GetShareLink$get_share_link$$OperationInfo$messages({
    this.code,
    this.field,
    required this.kind,
    required this.message,
    this.$__typename = 'OperationMessage',
  });

  factory Mutation$GetShareLink$get_share_link$$OperationInfo$messages.fromJson(
      Map<String, dynamic> json) {
    final l$code = json['code'];
    final l$field = json['field'];
    final l$kind = json['kind'];
    final l$message = json['message'];
    final l$$__typename = json['__typename'];
    return Mutation$GetShareLink$get_share_link$$OperationInfo$messages(
      code: (l$code as String?),
      field: (l$field as String?),
      kind: fromJson$Enum$OperationMessageKind((l$kind as String)),
      message: (l$message as String),
      $__typename: (l$$__typename as String),
    );
  }

  final String? code;

  final String? field;

  final Enum$OperationMessageKind kind;

  final String message;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$code = code;
    _resultData['code'] = l$code;
    final l$field = field;
    _resultData['field'] = l$field;
    final l$kind = kind;
    _resultData['kind'] = toJson$Enum$OperationMessageKind(l$kind);
    final l$message = message;
    _resultData['message'] = l$message;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$code = code;
    final l$field = field;
    final l$kind = kind;
    final l$message = message;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$code,
      l$field,
      l$kind,
      l$message,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (!(other
            is Mutation$GetShareLink$get_share_link$$OperationInfo$messages) ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$code = code;
    final lOther$code = other.code;
    if (l$code != lOther$code) {
      return false;
    }
    final l$field = field;
    final lOther$field = other.field;
    if (l$field != lOther$field) {
      return false;
    }
    final l$kind = kind;
    final lOther$kind = other.kind;
    if (l$kind != lOther$kind) {
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

extension UtilityExtension$Mutation$GetShareLink$get_share_link$$OperationInfo$messages
    on Mutation$GetShareLink$get_share_link$$OperationInfo$messages {
  CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
          Mutation$GetShareLink$get_share_link$$OperationInfo$messages>
      get copyWith =>
          CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
    TRes> {
  factory CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages(
    Mutation$GetShareLink$get_share_link$$OperationInfo$messages instance,
    TRes Function(Mutation$GetShareLink$get_share_link$$OperationInfo$messages)
        then,
  ) = _CopyWithImpl$Mutation$GetShareLink$get_share_link$$OperationInfo$messages;

  factory CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages.stub(
          TRes res) =
      _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$OperationInfo$messages;

  TRes call({
    String? code,
    String? field,
    Enum$OperationMessageKind? kind,
    String? message,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
        TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
            TRes> {
  _CopyWithImpl$Mutation$GetShareLink$get_share_link$$OperationInfo$messages(
    this._instance,
    this._then,
  );

  final Mutation$GetShareLink$get_share_link$$OperationInfo$messages _instance;

  final TRes Function(
      Mutation$GetShareLink$get_share_link$$OperationInfo$messages) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? code = _undefined,
    Object? field = _undefined,
    Object? kind = _undefined,
    Object? message = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(Mutation$GetShareLink$get_share_link$$OperationInfo$messages(
        code: code == _undefined ? _instance.code : (code as String?),
        field: field == _undefined ? _instance.field : (field as String?),
        kind: kind == _undefined || kind == null
            ? _instance.kind
            : (kind as Enum$OperationMessageKind),
        message: message == _undefined || message == null
            ? _instance.message
            : (message as String),
        $__typename: $__typename == _undefined || $__typename == null
            ? _instance.$__typename
            : ($__typename as String),
      ));
}

class _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
        TRes>
    implements
        CopyWith$Mutation$GetShareLink$get_share_link$$OperationInfo$messages<
            TRes> {
  _CopyWithStubImpl$Mutation$GetShareLink$get_share_link$$OperationInfo$messages(
      this._res);

  TRes _res;

  call({
    String? code,
    String? field,
    Enum$OperationMessageKind? kind,
    String? message,
    String? $__typename,
  }) =>
      _res;
}
