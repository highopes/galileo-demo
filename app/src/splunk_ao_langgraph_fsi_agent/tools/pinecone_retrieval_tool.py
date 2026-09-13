"""
A tool for retrieving information from the Pinecone vector database.
"""

from langchain.tools import BaseTool
from pinecone import Pinecone
from pydantic import BaseModel, Field, PrivateAttr
from splunk_ao import log
from typing_extensions import override


class RetrievalInput(BaseModel):
    """
    RetrievalInput is a Pydantic model representing the input schema for a document retrieval operation.
    Attributes:
        query (str): The search query used to find relevant documents.
        k (int, optional): The number of documents to retrieve. Defaults to 3.
    """

    query: str = Field(description="The search query to find relevant documents")
    k: int = Field(default=3, description="Number of documents to retrieve")


class PineconeRetrievalTool(BaseTool):
    """
    PineconeRetrievalTool is a tool for retrieving relevant information from a financial services knowledge base using Pinecone as a vector store.
    """

    name: str = "pinecone_retrieval"
    description: str = "Retrieve relevant information from the financial services knowledge base"
    args_schema: type[BaseModel] = RetrievalInput  # type: ignore

    _api_key: str = PrivateAttr()
    _index_name: str = PrivateAttr()
    _namespace: str = PrivateAttr()
    _text_field: str = PrivateAttr()

    def __init__(self, index_name: str, namespace: str, text_field: str, api_key: str):
        super().__init__()
        self._api_key = api_key
        self._index_name = index_name
        self._namespace = namespace
        self._text_field = text_field

    @override
    @log(span_type="retriever")
    def _run(self, query: str, k: int = 3) -> str:
        """Execute the retrieval"""
        try:
            index = Pinecone(api_key=self._api_key).Index(self._index_name)
            response = index.search(
                namespace=self._namespace,
                query={"inputs": {"text": query}, "top_k": max(1, min(k, 10))},
                fields=[self._text_field, "source", "title"],
            )
            payload = response.to_dict() if hasattr(response, "to_dict") else response
            hits = payload.get("result", {}).get("hits", []) if isinstance(payload, dict) else []
            if not hits:
                return "No relevant information found in the knowledge base."

            formatted_results = []
            for position, hit in enumerate(hits, 1):
                fields = hit.get("fields", {}) if isinstance(hit, dict) else {}
                content = fields.get(self._text_field, "")
                source = fields.get("source", "unknown")
                if content:
                    formatted_results.append(f"Document {position} ({source}):\n{content}\n")

            return "\n".join(formatted_results) or "No relevant information found in the knowledge base."

        except Exception as e:
            return f"Error retrieving information: {type(e).__name__}: {str(e)[:300]}"
