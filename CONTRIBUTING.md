# Contributions

We're just getting started here. Stay tuned!

**This project is not currently accepting PRs.**

## How to submit a bug report

While this project gets up and running, currently the fastest way to report an issue is through Apple's official channels:

* Report an issue on the [Apple Developer Forums for Foundation Models framework](https://developer.apple.com/forums/topics/machine-learning-and-ai/machine-learning-and-ai-foundation-models). The project team is there and can answer your questions.

* File a bug with [Apple Feedback Assistant](https://developer.apple.com/feedback-assistant/). Be sure to tag Foundation Models Framework and these get sent to the project team. 

Please describe your issue and include following:
* Model name and version
* Which Swift package you're using to access that model
* Any relevant device conditions like:
  * Operating system type, kernel, version (for example macOS 27.0)
  * Device type (for example, a server or an iPad Air M4)
* Steps to reproduce. 
  * A code snippet for API issues
  * For model response issues, we will need to be able to reproduce the issue to track down the underlying cause. Depending on what you feel comfortable sharing, please send one of:
    * Run `session.logFeedbackAttachment` and serialize to a JSON file
    * A `Transcript` serialized to JSON
    * Code snippet, including a prompt, any `@Generable` types used, and any `Tool` types used.
