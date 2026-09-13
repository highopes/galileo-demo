"""
A credit score agent for the Brahe Bank application.
"""

from langgraph.graph.graph import CompiledGraph
from langgraph.prebuilt import create_react_agent

from ..llm import create_chat_model
from ..tools.credit_score_tool import CreditScoreTool


def create_credit_score_agent() -> CompiledGraph:
    """
    Create an agent that can help with inquires about your credit score.

    returns: A compiled graph for this agent.
    """

    # Create an agent
    agent = create_react_agent(
        model=create_chat_model("Credit Score Agent"),
        tools=[CreditScoreTool()],
        prompt=(
            """
            You are an expert on credit score. Provide the user with their credit score from the credit_score_tool.
            """
        ),
        name="credit-score-agent",
    )

    # Uncomment the following lines to print the compiled graph to the console in Mermaid format
    # print("Compiled Credit Score Agent Graph:")
    # print(agent.get_graph().draw_mermaid())

    # Return the compiled graph
    return agent
