# Claude Code's conversation in the agents panel, for tests/windows.py alone (not tests/ui.sh: it
# seeds the conversation and the config this needs): a seeded conversation opens with
# its prompt box, the panel's font size and what follows from it, a reply drawn as Markdown, then a
# new conversation and one prompt (the fake CLI natively, a missing program under Wine)
wait-agents
cmd focus_agents
print-agents
print-agents 1
wait 50
print-agent-input
print-agents-metrics
cmd agents_font_increase
print-agents-metrics
print-agent-row 2
key Escape
agent-new claude
print-agent-input
agent-prompt hello
wait-agent ready|failed 30000
print-agent-live
print-agents
quit
