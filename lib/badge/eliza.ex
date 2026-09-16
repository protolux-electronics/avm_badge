defmodule Badge.Eliza do
  @moduledoc """
  Weizenbaum's ELIZA of 1966, running the DOCTOR script.

  Pure: `respond/2` takes a line and the state and returns the reply and the
  next state. The state carries which reassembly each rule used last, so
  the same complaint gets a different answer the second time, and the
  memory of what was said about "my" things, which comes back when a line
  has no keyword at all.

  The script is parsed on the host at compile time; the badge only walks
  lists of binaries. AtomVM has no `String` module, so input is tokenised a
  byte at a time.
  """

  @greeting "How do you do. Please tell me your problem."
  @farewell "Goodbye. It was nice talking to you."

  @quit ["bye", "goodbye", "quit", "exit"]

  # Rewrites applied to each word before a keyword is looked for.
  @pre [
    {"dont", ["don't"]},
    {"cant", ["can't"]},
    {"wont", ["won't"]},
    {"im", ["i", "am"]},
    {"i'm", ["i", "am"]},
    {"you're", ["you", "are"]},
    {"youre", ["you", "are"]},
    {"recollect", ["remember"]},
    {"dreamt", ["dreamed"]},
    {"dreams", ["dream"]},
    {"maybe", ["perhaps"]},
    {"how", ["what"]},
    {"when", ["what"]},
    {"certainly", ["yes"]},
    {"machine", ["computer"]},
    {"machines", ["computer"]},
    {"computers", ["computer"]},
    {"were", ["was"]},
    {"same", ["alike"]},
    {"identical", ["alike"]},
    {"equivalent", ["alike"]}
  ]

  # Rewrites applied to what the user said when it is echoed back.
  @post [
    {"am", ["are"]},
    {"are", ["am"]},
    {"your", ["my"]},
    {"yours", ["mine"]},
    {"me", ["you"]},
    {"myself", ["yourself"]},
    {"yourself", ["myself"]},
    {"i", ["you"]},
    {"you", ["I"]},
    {"my", ["your"]},
    {"mine", ["yours"]},
    {"i'd", ["you", "would"]},
    {"i've", ["you", "have"]},
    {"i'll", ["you", "will"]}
  ]

  @synonyms %{
    "be" => ["am", "is", "are", "was"],
    "belief" => ["feel", "think", "believe", "wish"],
    "cannot" => ["can't", "cannot"],
    "desire" => ["want", "need"],
    "everyone" => ["everyone", "everybody", "nobody", "noone"],
    "family" => [
      "mother",
      "mom",
      "father",
      "dad",
      "sister",
      "brother",
      "wife",
      "children",
      "child"
    ],
    "happy" => ["elated", "glad", "better", "happy"],
    "sad" => ["unhappy", "depressed", "sick", "sad"]
  }

  @none [
    "I'm not sure I understand you fully.",
    "Please go on.",
    "What does that suggest to you?",
    "Do you feel strongly about discussing such things?",
    "That is interesting. Please continue.",
    "Tell me more about that.",
    "Does talking about this bother you?"
  ]

  @none_rule for line <- @none, do: {[], [line]}

  # {keyword, rank, [{decomposition, reassemblies}]}. A `$` decomposition is
  # remembered rather than answered; `{:goto, key}` hands over to another rule.
  @rules [
    {"sorry", 1,
     [
       {"*",
        [
          "Please don't apologise.",
          "Apologies are not necessary.",
          "I've told you that apologies are not required.",
          "It did not bother me. Please continue."
        ]}
     ]},
    {"apologise", 1, [{"*", [{:goto, "sorry"}]}]},
    {"apologize", 1, [{"*", [{:goto, "sorry"}]}]},
    {"remember", 5,
     [
       {"* i remember *",
        [
          "Do you often think of (2)?",
          "Does thinking of (2) bring anything else to mind?",
          "What else do you recollect?",
          "Why do you remember (2) just now?",
          "What in the present situation reminds you of (2)?",
          "What is the connection between me and (2)?",
          "What else does (2) remind you of?"
        ]},
       {"* do you remember *",
        [
          "Did you think I would forget (2)?",
          "Why do you think I should recall (2) now?",
          "What about (2)?",
          {:goto, "what"},
          "You mentioned (2)?"
        ]},
       {"* you remember *",
        [
          "How could I forget (2)?",
          "What about (2) should I remember?",
          {:goto, "you"}
        ]},
       {"*", [{:goto, "what"}]}
     ]},
    {"forget", 5,
     [
       {"* i forget *",
        [
          "Can you think of why you might forget (2)?",
          "Why can't you remember (2)?",
          "How often do you think of (2)?",
          "Does it bother you to forget that?",
          "Could it be a mental block?",
          "Are you generally forgetful?",
          "Do you think you are suppressing (2)?"
        ]},
       {"* did you forget *",
        [
          "Why do you ask?",
          "Are you sure you told me?",
          "Would it bother you if I forgot (2)?",
          "Why do you think I should recall (2) now?",
          {:goto, "what"},
          "Tell me more about (2)."
        ]},
       {"*", [{:goto, "what"}]}
     ]},
    {"if", 3,
     [
       {"* if *",
        [
          "Do you think it's likely that (2)?",
          "Do you wish that (2)?",
          "What do you know about (2)?",
          "Really, if (2)?",
          "What would you do if (2)?",
          "But what are the chances that (2)?",
          "What does this speculation lead to?"
        ]}
     ]},
    {"dreamed", 4,
     [
       {"* i dreamed *",
        [
          "Really, (2)?",
          "Have you ever fantasized (2) while you were awake?",
          "Have you ever dreamed (2) before?",
          {:goto, "dream"}
        ]},
       {"*", [{:goto, "dream"}]}
     ]},
    {"dream", 3,
     [
       {"*",
        [
          "What does that dream suggest to you?",
          "Do you dream often?",
          "What persons appear in your dreams?",
          "Do you believe that dreams have something to do with your problem?"
        ]}
     ]},
    {"perhaps", 0,
     [
       {"*",
        [
          "You don't seem quite certain.",
          "Why the uncertain tone?",
          "Can't you be more positive?",
          "You aren't sure?",
          "Don't you know?",
          "How likely, would you estimate?"
        ]}
     ]},
    {"name", 15,
     [
       {"*",
        [
          "I am not interested in names.",
          "I've told you before, I don't care about names. Please continue."
        ]}
     ]},
    {"deutsch", 0, [{"*", [{:goto, "xforeign"}]}]},
    {"francais", 0, [{"*", [{:goto, "xforeign"}]}]},
    {"italiano", 0, [{"*", [{:goto, "xforeign"}]}]},
    {"espanol", 0, [{"*", [{:goto, "xforeign"}]}]},
    {"svenska", 0, [{"*", [{:goto, "xforeign"}]}]},
    {"xforeign", 0, [{"*", ["I speak only English."]}]},
    {"hello", 0,
     [
       {"*",
        [
          "How do you do. Please state your problem.",
          "Hi. What seems to be your problem?"
        ]}
     ]},
    {"hi", 0, [{"*", [{:goto, "hello"}]}]},
    {"computer", 50,
     [
       {"*",
        [
          "Do computers worry you?",
          "Why do you mention computers?",
          "What do you think machines have to do with your problem?",
          "Don't you think computers can help people?",
          "What about machines worries you?",
          "What do you think about machines?"
        ]}
     ]},
    {"am", 0,
     [
       {"* am i *",
        [
          "Do you believe you are (2)?",
          "Would you want to be (2)?",
          "Do you wish I would tell you you are (2)?",
          "What would it mean if you were (2)?",
          {:goto, "what"}
        ]},
       {"* i am *", [{:goto, "i"}]},
       {"*", ["Why do you say 'am'?", "I don't understand that."]}
     ]},
    {"are", 0,
     [
       {"* are you *",
        [
          "Why are you interested in whether I am (2) or not?",
          "Would you prefer if I weren't (2)?",
          "Perhaps I am (2) in your fantasies.",
          "Do you sometimes think I am (2)?",
          {:goto, "what"},
          "Would it matter to you?",
          "What if I were (2)?"
        ]},
       {"* you are *", [{:goto, "you"}]},
       {"* are *",
        [
          "Did you think they might not be (2)?",
          "Would you like it if they were not (2)?",
          "What if they were not (2)?",
          "Are they always (2)?",
          "Possibly they are (2).",
          "Are you positive they are (2)?"
        ]}
     ]},
    {"your", 0,
     [
       {"* your *",
        [
          "Why are you concerned over my (2)?",
          "What about your own (2)?",
          "Are you worried about someone else's (2)?",
          "Really, my (2)?",
          "What makes you think of my (2)?",
          "Do you want my (2)?"
        ]}
     ]},
    {"was", 2,
     [
       {"* was i *",
        [
          "What if you were (2)?",
          "Do you think you were (2)?",
          "Were you (2)?",
          "What would it mean if you were (2)?",
          "What does '(2)' suggest to you?",
          {:goto, "what"}
        ]},
       {"* i was *",
        [
          "Were you really?",
          "Why do you tell me you were (2) now?",
          "Perhaps I already know you were (2)."
        ]},
       {"* was you *",
        [
          "Would you like to believe I was (2)?",
          "What suggests that I was (2)?",
          "What do you think?",
          "Perhaps I was (2).",
          "What if I had been (2)?"
        ]}
     ]},
    {"i", 0,
     [
       {"* i @desire *",
        [
          "What would it mean to you if you got (3)?",
          "Why do you want (3)?",
          "Suppose you got (3) soon.",
          "What if you never got (3)?",
          "What would getting (3) mean to you?",
          "What does wanting (3) have to do with this discussion?"
        ]},
       {"* i am * @sad *",
        [
          "I am sorry to hear that you are (3).",
          "Do you think coming here will help you not to be (3)?",
          "I'm sure it's not pleasant to be (3).",
          "Can you explain what made you (3)?"
        ]},
       {"* i am * @happy *",
        [
          "How have I helped you to be (3)?",
          "Has your treatment made you (3)?",
          "What makes you (3) just now?",
          "Can you explain why you are suddenly (3)?"
        ]},
       {"* i was *", [{:goto, "was"}]},
       {"* i @belief i *",
        [
          "Do you really think so?",
          "But you are not sure you (3).",
          "Do you really doubt you (3)?"
        ]},
       {"* i * @belief * you *", [{:goto, "you"}]},
       {"* i am *",
        [
          "Is it because you are (2) that you came to me?",
          "How long have you been (2)?",
          "Do you believe it is normal to be (2)?",
          "Do you enjoy being (2)?",
          "Do you know anyone else who is (2)?"
        ]},
       {"* i @cannot *",
        [
          "How do you know that you can't (3)?",
          "Have you tried?",
          "Perhaps you could (3) now.",
          "Do you really want to be able to (3)?",
          "What if you could (3)?"
        ]},
       {"* i don't *",
        [
          "Don't you really (2)?",
          "Why don't you (2)?",
          "Do you wish to be able to (2)?",
          "Does that trouble you?"
        ]},
       {"* i feel *",
        [
          "Tell me more about such feelings.",
          "Do you often feel (2)?",
          "Do you enjoy feeling (2)?",
          "Of what does feeling (2) remind you?"
        ]},
       {"* i * you *",
        [
          "Perhaps in your fantasies we (2) each other.",
          "Do you wish to (2) me?",
          "You seem to need to (2) me.",
          "Do you (2) anyone else?"
        ]},
       {"*",
        [
          "You say (1)?",
          "Can you elaborate on that?",
          "Do you say (1) for some special reason?",
          "That's quite interesting."
        ]}
     ]},
    {"you", 0,
     [
       {"* you remind me of *", [{:goto, "alike"}]},
       {"* you are *",
        [
          "What makes you think I am (2)?",
          "Does it please you to believe I am (2)?",
          "Do you sometimes wish you were (2)?",
          "Perhaps you would like to be (2)."
        ]},
       {"* you * me *",
        [
          "Why do you think I (2) you?",
          "You like to think I (2) you, don't you?",
          "What makes you think I (2) you?",
          "Really, I (2) you?",
          "Do you wish to believe I (2) you?",
          "Suppose I did (2) you. What would that mean?",
          "Does someone else believe I (2) you?"
        ]},
       {"* you *",
        [
          "We were discussing you, not me.",
          "Oh, I (2)?",
          "You're not really talking about me, are you?",
          "What are your feelings now?"
        ]}
     ]},
    {"yes", 0,
     [
       {"*",
        [
          "You seem to be quite positive.",
          "You are sure.",
          "I see.",
          "I understand."
        ]}
     ]},
    {"no", 0,
     [
       {"* no one *",
        [
          "Are you sure, no one (2)?",
          "Surely someone (2).",
          "Can you think of anyone at all?",
          "Are you thinking of a very special person?",
          "Who, may I ask?",
          "You have a particular person in mind, don't you?",
          "Who do you think you are talking about?"
        ]},
       {"*",
        [
          "Are you saying no just to be negative?",
          "You are being a bit negative.",
          "Why not?",
          "Why 'no'?"
        ]}
     ]},
    {"my", 2,
     [
       {"$ * my *",
        [
          "Does that have anything to do with the fact that your (2)?",
          "Lets discuss further why your (2).",
          "Earlier you said your (2).",
          "But your (2)."
        ]},
       {"* my * @family *",
        [
          "Tell me more about your family.",
          "Who else in your family (4)?",
          "Your (3)?",
          "What else comes to your mind when you think of your (3)?"
        ]},
       {"* my *",
        [
          "Your (2)?",
          "Why do you say your (2)?",
          "Does that suggest anything else which belongs to you?",
          "Is it important to you that your (2)?"
        ]}
     ]},
    {"can", 0,
     [
       {"* can you *",
        [
          "You believe I can (2), don't you?",
          {:goto, "what"},
          "You want me to be able to (2).",
          "Perhaps you would like to be able to (2) yourself."
        ]},
       {"* can i *",
        [
          "Whether or not you can (2) depends on you more than on me.",
          "Do you want to be able to (2)?",
          "Perhaps you don't want to (2).",
          {:goto, "what"}
        ]}
     ]},
    {"what", 0,
     [
       {"*",
        [
          "Why do you ask?",
          "Does that question interest you?",
          "What is it you really want to know?",
          "Are such questions much on your mind?",
          "What answer would please you most?",
          "What do you think?",
          "What comes to mind when you ask that?",
          "Have you asked such questions before?",
          "Have you asked anyone else?"
        ]}
     ]},
    {"because", 0,
     [
       {"*",
        [
          "Is that the real reason?",
          "Don't any other reasons come to mind?",
          "Does that reason seem to explain anything else?",
          "What other reasons might there be?"
        ]}
     ]},
    {"why", 0,
     [
       {"* why don't you *",
        [
          "Do you believe I don't (2)?",
          "Perhaps I will (2) in good time.",
          "Should you (2) yourself?",
          "You want me to (2)?",
          {:goto, "what"}
        ]},
       {"* why can't i *",
        [
          "Do you think you should be able to (2)?",
          "Do you want to be able to (2)?",
          "Do you believe this will help you to (2)?",
          "Have you any idea why you can't (2)?",
          {:goto, "what"}
        ]},
       {"*", [{:goto, "what"}]}
     ]},
    {"everyone", 2,
     [
       {"* @everyone *",
        [
          "Really, (2)?",
          "Surely not (2).",
          "Can you think of anyone in particular?",
          "Who, for example?",
          "Are you thinking of a very special person?",
          "Who, may I ask?",
          "Someone special perhaps?",
          "You have a particular person in mind, don't you?",
          "Who do you think you're talking about?"
        ]}
     ]},
    {"everybody", 2, [{"*", [{:goto, "everyone"}]}]},
    {"nobody", 2, [{"*", [{:goto, "everyone"}]}]},
    {"noone", 2, [{"*", [{:goto, "everyone"}]}]},
    {"always", 1,
     [
       {"*",
        [
          "Can you think of a specific example?",
          "When?",
          "What incident are you thinking of?",
          "Really, always?"
        ]}
     ]},
    {"alike", 10,
     [
       {"*",
        [
          "In what way?",
          "What resemblance do you see?",
          "What does that similarity suggest to you?",
          "What other connections do you see?",
          "What do you suppose that resemblance means?",
          "What is the connection, do you suppose?",
          "Could there really be some connection?",
          "How?"
        ]}
     ]},
    {"like", 10, [{"* @be * like *", [{:goto, "alike"}]}]},
    {"different", 0,
     [
       {"*",
        [
          "How is it different?",
          "What differences do you see?",
          "What does that difference suggest to you?",
          "What other distinctions do you see?",
          "What do you suppose that disparity means?",
          "Could there be some connection, do you suppose?",
          "How?"
        ]}
     ]}
  ]

  # Host-only: the script is parsed here, at compile time, into what the badge walks.
  @script (fn ->
             parse_decomp = fn text ->
               {memory?, pattern} =
                 case String.split(text, " ", trim: true) do
                   ["$" | rest] -> {true, rest}
                   rest -> {false, rest}
                 end

               tokens =
                 for word <- pattern do
                   case word do
                     "*" -> :*
                     "@" <> name -> {:any, Map.fetch!(@synonyms, name)}
                     plain -> plain
                   end
                 end

               {memory?, tokens}
             end

             parse_reassembly = fn
               {:goto, key} ->
                 {:goto, key}

               text ->
                 ~r/\((\d+)\)/
                 |> Regex.split(text, include_captures: true, trim: true)
                 |> Enum.map(fn
                   "(" <> rest -> {:part, String.to_integer(String.trim_trailing(rest, ")"))}
                   literal -> literal
                 end)
             end

             # Which captures a reassembly reads; one that reads an empty capture is skipped.
             needed = fn
               {:goto, _key} -> []
               parts -> for {:part, n} <- parts, uniq: true, do: n
             end

             for {key, rank, decomps} <- @rules do
               parsed =
                 for {decomp, reassemblies} <- decomps do
                   {memory?, tokens} = parse_decomp.(decomp)

                   parsed =
                     Enum.map(reassemblies, fn r ->
                       parts = parse_reassembly.(r)
                       {needed.(parts), parts}
                     end)

                   {memory?, tokens, parsed}
                 end

               {key, rank, parsed}
             end
           end).()

  for {_key, _rank, decomps} <- @script,
      {_memory?, _tokens, reassemblies} <- decomps,
      {_needed, {:goto, target}} <- reassemblies do
    List.keymember?(@script, target, 0) || raise "goto #{target}: no such rule"
  end

  @doc "A fresh conversation."
  @spec new() :: map
  def new, do: %{cycles: %{}, memory: []}

  @doc "What ELIZA says first."
  @spec greeting() :: binary
  def greeting, do: @greeting

  @doc "Whether a line ended the conversation."
  @spec farewell?(binary) :: boolean
  def farewell?(reply), do: reply == @farewell

  @doc "The reply to one line, and the state to answer the next with."
  @spec respond(binary, map) :: {binary, map}
  def respond(input, state) do
    clauses = clauses(input)

    case quit?(clauses) do
      true -> {@farewell, state}
      false -> answer(keyed(clauses), state)
    end
  end

  defp quit?(clauses) do
    :lists.any(fn clause -> :lists.any(&:lists.member(&1, @quit), clause) end, clauses)
  end

  # The first clause with a keyword answers for the whole line.
  defp keyed([]), do: nil

  defp keyed([clause | rest]) do
    case best_keyword(clause, nil) do
      nil -> keyed(rest)
      key -> {key, clause}
    end
  end

  defp best_keyword([], best), do: best

  defp best_keyword([word | rest], best) do
    case :lists.keyfind(word, 1, @script) do
      {key, rank, _decomps} when best == nil -> best_keyword(rest, {key, rank})
      {key, rank, _decomps} when rank > elem(best, 1) -> best_keyword(rest, {key, rank})
      _other -> best_keyword(rest, best)
    end
  end

  defp answer(nil, %{memory: [line | rest]} = state), do: {line, %{state | memory: rest}}
  defp answer(nil, state), do: cycle(@none_rule, {:none, 0}, [], state)

  # A keyword none of whose patterns fit gets a stock reply, not a memory.
  defp answer({{key, _rank}, clause}, state) do
    state = remember(key, clause, state)

    case try_rule(key, clause, state) do
      nil -> cycle(@none_rule, {:none, 0}, [], state)
      reply -> reply
    end
  end

  # A line about "my" something is kept for when there is nothing else to say.
  defp remember(key, clause, state) do
    {_key, _rank, decomps} = :lists.keyfind(key, 1, @script)

    case :lists.filter(fn {memory?, _tokens, _reassemblies} -> memory? end, decomps) do
      [{true, tokens, reassemblies}] -> remember(tokens, reassemblies, key, clause, state)
      _none -> state
    end
  end

  defp remember(tokens, reassemblies, key, clause, state) do
    with {:ok, captures} <- match(tokens, clause),
         {line, state} when is_binary(line) <-
           cycle(reassemblies, {key, :memory}, captures, state) do
      %{state | memory: state.memory ++ [line]}
    else
      _other -> state
    end
  end

  defp try_rule(key, clause, state) do
    {_key, _rank, decomps} = :lists.keyfind(key, 1, @script)

    try_decomps(decomps, 0, key, clause, state)
  end

  defp try_decomps([], _index, _key, _clause, _state), do: nil

  defp try_decomps([{true, _tokens, _reassemblies} | rest], index, key, clause, state) do
    try_decomps(rest, index + 1, key, clause, state)
  end

  defp try_decomps([{false, tokens, reassemblies} | rest], index, key, clause, state) do
    with {:ok, captures} <- match(tokens, clause),
         {reply, state} <- cycle(reassemblies, {key, index}, captures, state) do
      case reply do
        {:goto, target} -> try_rule(target, clause, state)
        line -> {line, state}
      end
    else
      _other -> try_decomps(rest, index + 1, key, clause, state)
    end
  end

  # Each rule hands out its reassemblies in turn, wrapping round. One that
  # would echo an empty capture is passed over; nil when every one would.
  defp cycle(reassemblies, slot, captures, state) do
    used = Map.get(state.cycles, slot, 0)

    case usable(reassemblies, used, length(reassemblies), captures) do
      nil ->
        nil

      {skipped, parts} ->
        state = %{state | cycles: Map.put(state.cycles, slot, used + skipped + 1)}

        {reply(parts, captures), state}
    end
  end

  defp usable(_reassemblies, _used, 0, _captures), do: nil

  defp usable(reassemblies, used, left, captures) do
    {needed, parts} = :lists.nth(rem(used, length(reassemblies)) + 1, reassemblies)

    case :lists.all(fn n -> :lists.nth(n, captures) != [] end, needed) do
      true -> {length(reassemblies) - left, parts}
      false -> usable(reassemblies, used + 1, left - 1, captures)
    end
  end

  defp reply({:goto, _target} = goto, _captures), do: goto
  defp reply(parts, captures), do: assemble(parts, captures, [])

  defp assemble([], _captures, acc), do: :erlang.iolist_to_binary(:lists.reverse(acc))

  defp assemble([{:part, n} | rest], captures, acc) do
    words = :lists.map(&reflect/1, :lists.nth(n, captures))

    assemble(rest, captures, [join(:lists.foldr(fn w, acc -> w ++ acc end, [], words)) | acc])
  end

  defp assemble([literal | rest], captures, acc), do: assemble(rest, captures, [literal | acc])

  defp reflect(word) do
    case :lists.keyfind(word, 1, @post) do
      {_word, words} -> words
      false -> [word]
    end
  end

  defp join([]), do: <<>>
  defp join([word]), do: word
  defp join([word | rest]), do: word <> " " <> join(rest)

  @doc """
  Matches a decomposition against a clause, returning the captures in order.

  `:*` takes any run of words, including none; a synonym set takes exactly
  one; a literal word takes itself. Every capture is a word list.
  """
  @spec match([term], [binary]) :: {:ok, [[binary]]} | :nomatch
  def match(tokens, words), do: match(tokens, words, [])

  defp match([], [], acc), do: {:ok, :lists.reverse(acc)}
  defp match([], _words, _acc), do: :nomatch

  defp match([:* | rest], words, acc), do: star(rest, words, [], acc)

  defp match([{:any, set} | rest], [word | words], acc) do
    case :lists.member(word, set) do
      true -> match(rest, words, [[word] | acc])
      false -> :nomatch
    end
  end

  defp match([word | rest], [word | words], acc), do: match(rest, words, acc)
  defp match(_tokens, _words, _acc), do: :nomatch

  # Takes the shortest run first, growing it one word at a time.
  defp star(rest, words, taken, acc) do
    case match(rest, words, [:lists.reverse(taken) | acc]) do
      {:ok, captures} -> {:ok, captures}
      :nomatch -> longer(rest, words, taken, acc)
    end
  end

  defp longer(_rest, [], _taken, _acc), do: :nomatch
  defp longer(rest, [word | words], taken, acc), do: star(rest, words, [word | taken], acc)

  @doc """
  Splits a line into clauses of lowercased words, with the pre-substitutions applied.

  Punctuation ends a clause; anything that is not a letter, digit or
  apostrophe ends a word.
  """
  @spec clauses(binary) :: [[binary]]
  def clauses(input), do: scan(input, 0, byte_size(input), [], [], [])

  defp scan(_input, at, size, word, clause, acc) when at >= size do
    :lists.reverse(finish_clause(finish_word(word, clause), acc))
  end

  defp scan(input, at, size, word, clause, acc) do
    char = :binary.at(input, at)

    cond do
      char >= ?a and char <= ?z ->
        scan(input, at + 1, size, [char | word], clause, acc)

      char >= ?A and char <= ?Z ->
        scan(input, at + 1, size, [char + 32 | word], clause, acc)

      char >= ?0 and char <= ?9 ->
        scan(input, at + 1, size, [char | word], clause, acc)

      char == ?' ->
        scan(input, at + 1, size, [char | word], clause, acc)

      :lists.member(char, [?., ?,, ?!, ??, ?;]) ->
        scan(input, at + 1, size, [], [], finish_clause(finish_word(word, clause), acc))

      true ->
        scan(input, at + 1, size, [], finish_word(word, clause), acc)
    end
  end

  defp finish_word([], clause), do: clause

  defp finish_word(word, clause) do
    binary = :erlang.list_to_binary(:lists.reverse(word))

    case :lists.keyfind(binary, 1, @pre) do
      {_word, words} -> :lists.reverse(words) ++ clause
      false -> [binary | clause]
    end
  end

  defp finish_clause([], acc), do: acc
  defp finish_clause(clause, acc), do: [:lists.reverse(clause) | acc]
end
