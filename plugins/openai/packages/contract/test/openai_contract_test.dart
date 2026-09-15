import 'package:openai_contract/openai_contract.dart';
import 'package:test/test.dart';

void main() {
  test(
    'exports distinct durable native replay and presentation identities',
    () {
      expect(openAiResponsesItemKind, 'openai.responses.item.v1');
      expect(openAiResponsesItemVersion, 1);
      expect(
        openAiReasoningSummaryPresentationKind,
        'openai.responses.reasoning-summary.v1',
      );
      expect(openAiReasoningSummaryPresentationVersion, 1);
      expect(
        openAiReasoningSummaryPresentationKind,
        isNot(openAiResponsesItemKind),
      );
    },
  );
}
