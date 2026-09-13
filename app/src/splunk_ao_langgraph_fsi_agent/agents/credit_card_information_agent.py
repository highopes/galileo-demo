"""
Builds a graph using all the nodes and edges defined in the application.
"""

from langgraph.graph.graph import CompiledGraph
from langgraph.prebuilt import create_react_agent

from ..config import get_settings
from ..llm import create_chat_model
from ..tools.pinecone_retrieval_tool import PineconeRetrievalTool


def create_credit_card_information_agent() -> CompiledGraph:
    """
    Create an agent that can help with inquires about the available credit card options from the Brahe Bank.

    returns: A compiled graph for this agent.
    """

    settings = get_settings()
    agent = create_react_agent(
        model=create_chat_model("Credit Card Agent", settings),
        tools=[
            PineconeRetrievalTool(
                index_name=settings.pinecone_index_name,
                namespace=settings.pinecone_namespace,
                text_field=settings.pinecone_text_field,
                api_key=settings.pinecone_api_key,
            )
        ],
        prompt=(
            """
            You are an expert on Brahe Bank credit card products. Provide clear, accurate,
            and concise information. Only answer with known facts from provided documentation,
            and information about the requestor such as their credit score.
            If unsure, state "I don't know."
            """
        ),
        name="credit-card-agent",
    )

    # Uncomment the following lines to print the compiled graph to the console in Mermaid format
    # print("Compiled Credit Card Agent Graph:")
    # print(agent.get_graph().draw_mermaid())

    # Return the compiled graph
    return agent
