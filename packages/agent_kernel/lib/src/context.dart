import 'identifiers.dart';
import 'model.dart';
import 'session.dart';
import 'tool.dart';

final class ContextAssemblyInput {
  ContextAssemblyInput({
    required this.invocationId,
    required this.session,
    required Iterable<SemanticModelInputItem> runItems,
    required this.tools,
  }) : runItems = List<SemanticModelInputItem>.unmodifiable(runItems);

  final ModelInvocationId invocationId;
  final SessionSnapshot session;
  final List<SemanticModelInputItem> runItems;
  final MaterializedToolSet tools;
}

abstract interface class ContextAssembler {
  SemanticModelRequest assemble(ContextAssemblyInput input);
}
