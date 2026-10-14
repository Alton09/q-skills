## Asking the user

Standalone runs use `AskUserQuestion`, up to four questions per call. With `--worker`, do not use `AskUserQuestion`. A background session blocks on it, and the lead's `SendMessage` cannot answer it, so the run would hang. First let in-flight sub-agents of the current step finish and stop their runaway-guard timers, so no task notification starts a new turn. Then end the turn with this block:

```
<skill>: needs input <id>
Question: <one line>
Options:
1. <option> — <what the skill does next>
2. <option> — <what the skill does next>
Recommendation: <option number and one-line reason>
```

Put several questions in one numbered block. The next turn, typed with `claude attach` or sent by the lead with `SendMessage`, is the answer. Resume from the step that asked. If that turn is not an answer, handle it and end the turn with the same block again. Restate what happens for every option so compaction cannot lose it.
