defmodule Vibe.AI.ToolRegistry do
  @tools [
    %{
      id: "search_google",
      name: "Web Search",
      description: "Search the web for up-to-date information."
    },
    %{
      id: "analyze_image",
      name: "Image Analysis",
      description: "Describe or inspect an image URL."
    },
    %{
      id: "analyze_document",
      name: "Document Analysis",
      description: "Summarize or inspect a document URL."
    },
    %{
      id: "create_document",
      name: "Create Document",
      description: "Create or replace a spreadsheet or document output."
    },
    %{
      id: "find_rows",
      name: "Find Rows",
      description: "Search spreadsheet rows before editing or exporting."
    },
    %{
      id: "edit_rows",
      name: "Edit Rows",
      description: "Update specific spreadsheet rows by index."
    },
    %{
      id: "delete_rows",
      name: "Delete Rows",
      description: "Delete spreadsheet rows by index."
    },
    %{
      id: "export_rows",
      name: "Export Rows",
      description: "Export spreadsheet data to PNG or PDF."
    },
    %{
      id: "delete_document",
      name: "Delete Document",
      description: "Delete the active generated document."
    },
    %{
      id: "call_connected_app",
      name: "Connected App Action",
      description: "Call a configured app endpoint for business data or app-side actions."
    }
  ]

  def tools, do: @tools

  def tool_ids, do: Enum.map(@tools, & &1.id)

  def default_tool_ids, do: tool_ids()
end
