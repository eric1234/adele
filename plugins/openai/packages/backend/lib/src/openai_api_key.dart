String validateOpenAiApiKey(String apiKey) {
  if (apiKey.trim().isEmpty || apiKey != apiKey.trim()) {
    throw const FormatException('OpenAI API key must be nonempty and trimmed.');
  }
  if (apiKey.contains('\r') || apiKey.contains('\n')) {
    throw const FormatException('OpenAI API key contains invalid characters.');
  }
  return apiKey;
}
