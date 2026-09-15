import 'package:flutter/material.dart';

import 'src/chat_frontend_bridge.dart';

Widget buildChat() => ChatFrontend();

class ChatFrontend extends StatefulWidget {
  @override
  State<ChatFrontend> createState() => _ChatFrontendState();
}

class _ChatFrontendState extends State<ChatFrontend> {
  final TextEditingController controller = TextEditingController();
  bool disposed = false;

  @override
  void initState() {
    super.initState();
    subscribeChatChanges(() {
      if (disposed) return;
      setState(() {});
    });
  }

  void submit() {
    if (disposed) return;
    final String prompt = controller.text;
    if (prompt.trim().isEmpty) return;
    if (submitChatPrompt(prompt) && !disposed) controller.clear();
  }

  @override
  void dispose() {
    disposed = true;
    unsubscribeChatChanges();
    controller.dispose();
    super.dispose();
  }

  Widget activity(ChatPresentationEntry entry) =>
      buildChatActivity(entry.id!) ?? SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    final ChatPresentationSnapshot snapshot = readChatSnapshot();
    final List<Widget> children = <Widget>[
      Text('Chat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      SizedBox(height: 16),
    ];
    for (final ChatPresentationEntry entry in snapshot.entries) {
      if (entry.kind == 'activity') {
        children.add(activity(entry));
      } else {
        children.add(
          Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Align(
              alignment: entry.role == 'user'
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: entry.role == 'user'
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.role == 'user' ? 'You' : 'ADELE',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(entry.content),
                ],
              ),
            ),
          ),
        );
      }
    }
    // flutter_eval 0.8.2 does not bridge TextField.decoration.
    children.add(Text('Ask ADELE...'));
    children.add(
      TextField(
        controller: controller,
        enabled: snapshot.canSubmit,
        onSubmitted: (String value) => submit(),
      ),
    );
    if (snapshot.canSubmit) {
      children.add(
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => submit(), child: Text('Send')),
        ),
      );
    } else {
      // The pin declares TextButton.onPressed as non-nullable. A non-actionable
      // label avoids a broken nullable callback while submission is unavailable.
      children.add(
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('Send', style: TextStyle(color: Colors.grey)),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
