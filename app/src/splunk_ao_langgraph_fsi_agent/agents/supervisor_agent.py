"""
Supervisor Agent for Brahe Bank Application
"""

from langgraph_supervisor import create_supervisor

from .credit_card_information_agent import create_credit_card_information_agent
from .credit_score_agent import create_credit_score_agent
from ..llm import create_chat_model
from ..prompt_profiles import resolve_supervisor_prompt


def create_supervisor_agent(prompt_profile: str | None = None):
    """
    Create a supervisor agent that manages all the agents in the Brahe Bank application.
    """
    resolved_profile, supervisor_prompt = resolve_supervisor_prompt(prompt_profile)
    bank_supervisor_agent = create_supervisor(
        model=create_chat_model("Supervisor"),
        agents=[create_credit_card_information_agent(), create_credit_score_agent()],
        prompt=supervisor_prompt,
        add_handoff_back_messages=True,
        output_mode="full_history",
        supervisor_name="brahe-bank-supervisor-agent",
    ).compile()
    bank_supervisor_agent.name = "brahe-bank-supervisor-agent"

    # Uncomment the following lines to print the compiled graph to the console in Mermaid format
    # print("Compiled Bank Supervisor Agent Graph:")
    # print(bank_supervisor_agent.get_graph().draw_mermaid())

    return bank_supervisor_agent
