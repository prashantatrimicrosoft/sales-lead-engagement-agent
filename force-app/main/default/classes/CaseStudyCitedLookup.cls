/**
 * CaseStudyCitedLookup
 *
 * Replaces the native generatePromptResponse://Find_Relevant_Case_Study action.
 * Confirmed via Agent Trace inspection: the native action's output payload
 * carries no "citations" key at all during live execution, even though
 * citations render correctly in Prompt Builder's own isolated preview and
 * even with citationMode="Inline" set on the action input. Per Salesforce's
 * documented citations guide, only actions that explicitly return
 * AiCopilot.GenAiCitationInput feed source data into the agent's reasoning
 * context in a way that survives being referenced by later subagent turns
 * (Research_Agent's findings step, Outreach_Agent's final synthesis).
 *
 * This class calls the same "Find_Relevant_Case_Study" prompt template via
 * Connect API (same template, same inputs - no change to the underlying
 * prompt or retriever), but explicitly transforms and attaches citation
 * data the way the native no-code action does not.
 *
 * Adapted from Salesforce's own reference implementation:
 * https://developer.salesforce.com/docs/ai/agentforce/guide/citations.html
 */
public class CaseStudyCitedLookup {

    // Test method for debugging execute() directly from Developer Console / Anonymous Apex.
    public static void test() {
        execute('Electronics', 'Edge Communications opened a second manufacturing facility.');
    }

    // Calls the "Find_Relevant_Case_Study" Prompt Template via Connect API,
    // requesting citations be generated after the response (matches the
    // literal value used in Salesforce's own documented example).
    public static ConnectApi.EinsteinPromptTemplateGenerationsRepresentation execute(String industry, String additionalContext) {
        ConnectApi.WrappedValue industryInput = new ConnectApi.WrappedValue();
        industryInput.value = industry;

        ConnectApi.WrappedValue contextInput = new ConnectApi.WrappedValue();
        contextInput.value = additionalContext;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        // NOTE: these keys must exactly match the Prompt Template's input
        // variable API names - "Input:industry" and "Input:additional_context",
        // same as the existing generatePromptResponse action's wiring.
        inputParams.put('Input:industry', industryInput);
        inputParams.put('Input:additional_context', contextInput);

        ConnectApi.EinsteinPromptTemplateGenerationsInput executeTemplateInput = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        executeTemplateInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        executeTemplateInput.additionalConfig.applicationName = 'PromptBuilderPreview';
        executeTemplateInput.isPreview = false;
        // NOTE: 'post_generation' is the literal value from Salesforce's own
        // documented example - this differs from "Inline", which is what the
        // native no-code action's citationMode input was set to. Worth
        // testing whether this value alone (even without the Apex wrapper)
        // changes native-action behavior, though trace evidence suggests
        // the native action doesn't return a citations key regardless.
        executeTemplateInput.citationMode = 'post_generation';
        executeTemplateInput.inputParams = inputParams;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation generationsOutput = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
            'Find_Relevant_Case_Study', // Developer Name of the existing Prompt Template - unchanged
            executeTemplateInput
        );

        return generationsOutput;
    }

    // Transforms a single Connect API source reference to AiCopilot format.
    public static AiCopilot.GenAiSourceReference transform(ConnectApi.EinsteinLlmGenAiSourceReference sourceRef) {
        List<AiCopilot.GenAiSourceContentInfo> contents = new List<AiCopilot.GenAiSourceContentInfo>();
        for (ConnectApi.EinsteinLlmGenerationGenAiSourceContentInfo contentInfo : sourceRef.contents) {
            contents.add(new AiCopilot.GenAiSourceContentInfo(contentInfo.fieldName, contentInfo.objectName, contentInfo.content));
        }

        List<AiCopilot.GenAiSourceReferenceInfo> metadata = new List<AiCopilot.GenAiSourceReferenceInfo>();
        for (ConnectApi.EinsteinLlmGenerationGenAiSourceReferenceInfo referenceInfo : sourceRef.metadata) {
            metadata.add(new AiCopilot.GenAiSourceReferenceInfo(referenceInfo.link, referenceInfo.sourceObjectRecordId, referenceInfo.sourceObjectApiName));
        }

        return new AiCopilot.GenAiSourceReference(null, contents, metadata);
    }

    // Transforms the overall Connect API citation block to AiCopilot format.
    public static AiCopilot.GenAiCitationInput transform(ConnectApi.EinsteinLlmGenerationCitationOutput citations) {
        List<AiCopilot.GenAiSourceReference> sourceRefs = new List<AiCopilot.GenAiSourceReference>();
        if (citations != null && citations.sourceReferences != null) {
            for (ConnectApi.EinsteinLlmGenAiSourceReference source : citations.sourceReferences) {
                sourceRefs.add(transform(source));
            }
        }
        return new AiCopilot.GenAiCitationInput(null, sourceRefs);
    }

    // Input/output structures for the Invocable Method - these become the
    // action's configurable inputs/outputs in Agentforce Builder once deployed.
    public class Request {
        @InvocableVariable(required=true description='The account industry, used to find a relevant case study proof point.')
        public String Industry;

        @InvocableVariable(required=false description='Optional situational context about the account, used to sharpen the case study match.')
        public String AdditionalContext;
    }

    public class Response {
        @InvocableVariable(required=true description='The case study proof point text generated from the prompt template.')
        public String CaseStudySummary;

        @InvocableVariable(required=true description='Structured citation sources for the case study, readable by the agent reasoning engine across subsequent turns.')
        public AiCopilot.GenAiCitationInput sources;
    }

    // @InvocableMethod for Agentforce: takes industry + additional_context,
    // calls the existing prompt template, transforms citations, and returns
    // both the summary text and citation sources together.
    @InvocableMethod(label='Find Relevant Case Study (Cited)' description='Finds the most relevant case study for an account and returns it with structured, agent-readable citations.')
    public static List<Response> executeCaseStudyLookup(List<Request> requests) {
        String industry = requests[0].Industry;
        String additionalContext = requests[0].AdditionalContext;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output = execute(industry, additionalContext);

        List<Response> responses = new List<Response>();
        Response response = new Response();
        response.CaseStudySummary = output.prompt;
        response.sources = transform(output.citations);
        responses.add(response);

        return responses;
    }
}