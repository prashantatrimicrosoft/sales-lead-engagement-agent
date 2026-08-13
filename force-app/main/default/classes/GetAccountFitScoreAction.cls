/**
 * GetAccountFitScoreAction
 * ---------------------------------------------------------------------
 * Invocable Apex action that looks up an Account's calculated Fit Score
 * from a Data Cloud Calculated Insight (e.g. Account_Fit_Score_Final)
 * and returns it in a shape an Agentforce agent can reason over.
 *
 * Register this as an Agent Action in Agentforce Builder and add it to
 * the "Research Agent" subagent's action list (alongside / instead of
 * "Find Product Fit").
 *
 * Schema confirmed via a SELECT * metadata probe against Account_Fit_Score_Final__cio
 * (Data Explorer's column headers omit the "__c" suffix, but the query
 * engine requires it):
 *     account_id__c   - Salesforce Account Id (18-char), VARCHAR
 *     fit_score__c    - Decimal, e.g. 0.15 - 0.90
 *     industry__c     - Text
 *
 * Notes:
 *  1. Calculated Insight OBJECTS are queried with the suffix "__cio"
 *     appended to the developer name shown in Data Explorer
 *     (e.g. "Account_Fit_Score_Final__cio").
 *  2. Calculated Insight COLUMNS also carry a "__c" suffix in the
 *     query engine even though Data Explorer displays them without it
 *     (confirmed: account_id -> account_id__c, etc.). If you add this
 *     action for a different insight, don't assume Data Explorer's
 *     column names are query-ready — run a "SELECT * ... LIMIT 3" probe
 *     and read response.metadata to get the real names first.
 *  3. This code must run in the org where Data Cloud is enabled
 *     (ConnectApi.CdpQuery only works there, not in a connected org).
 *  4. The running user needs Data Cloud / CDP query permissions
 *     (e.g. Data Cloud Standard or a custom permission set with
 *     "Manage Data Cloud" / CDP query access).
 */
public with sharing class GetAccountFitScoreAction {

    // --- Confirmed via SELECT * metadata against Account_Fit_Score_Final__cio ---
    private static final String CALCULATED_INSIGHT_API_NAME = 'Account_Fit_Score_Final__cio';
    private static final String FIELD_ACCOUNT_ID = 'account_id__c';
    private static final String FIELD_FIT_SCORE  = 'fit_score__c';
    private static final String FIELD_INDUSTRY   = 'industry__c';

    public class RequestInput {
        @InvocableVariable(
            label='Account ID'
            description='The 15 or 18-character Salesforce Account Id to look up the Fit Score for.'
            required=true
        )
        public String accountId;
    }

    public class ResponseOutput {
        @InvocableVariable(label='Found' description='Whether a Fit Score insight was found for this account.')
        public Boolean isSuccess;

        @InvocableVariable(label='Fit Score' description='The numeric Fit Score, if found.')
        public Decimal fitScore;

        @InvocableVariable(label='Industry' description='The account industry as recorded on the calculated insight.')
        public String industry;

        @InvocableVariable(label='Summary' description='A plain-language summary the agent can use directly in a response.')
        public String summary;
    }

    @InvocableMethod(
        label='Get Account Fit Score'
        description='Looks up the latest Data Cloud Calculated Insight Fit Score for an Account and returns the score, industry, and a short summary for use in outreach or research reasoning.'
        category='Data Cloud Insights'
    )
    public static List<ResponseOutput> getFitScore(List<RequestInput> requests) {
        List<ResponseOutput> results = new List<ResponseOutput>();

        for (RequestInput req : requests) {
            ResponseOutput out = new ResponseOutput();

            if (String.isBlank(req.accountId)) {
                out.isSuccess = false;
                out.summary = 'No Account Id was provided, so no Fit Score could be looked up.';
                results.add(out);
                continue;
            }

            try {
                String safeAccountId = String.escapeSingleQuotes(req.accountId);

                // Column order here MUST match the positional read of
                // resultRow.rowData below (0=account_id, 1=fit_score, 2=industry).
                // If you change this SELECT list, update the rowData indices too.
                String sql =
                    'SELECT ' + FIELD_ACCOUNT_ID + ', ' + FIELD_FIT_SCORE + ', ' + FIELD_INDUSTRY +
                    ' FROM ' + CALCULATED_INSIGHT_API_NAME +
                    ' WHERE ' + FIELD_ACCOUNT_ID + ' = \'' + safeAccountId + '\'' +
                    ' LIMIT 1';

                ConnectApi.CdpQueryInput queryInput = new ConnectApi.CdpQueryInput();
                queryInput.sql = sql;

                ConnectApi.CdpQueryOutputV2 response = ConnectApi.CdpQuery.queryAnsiSqlV2(queryInput);

                if (response != null && response.data != null && !response.data.isEmpty()) {
                    // response.data is a List<ConnectApi.CdpQueryV2Row>.
                    // Each row's values come back positionally in rowData,
                    // in the same order as the SELECT list above:
                    // 0 = account_id, 1 = fit_score, 2 = industry
                    ConnectApi.CdpQueryV2Row resultRow = response.data[0];

                    Object scoreVal = resultRow.rowData[1];
                    out.fitScore = scoreVal != null
                        ? Decimal.valueOf(String.valueOf(scoreVal)).setScale(2)
                        : null;

                    Object industryVal = resultRow.rowData[2];
                    out.industry = industryVal != null ? String.valueOf(industryVal) : null;

                    out.isSuccess = true;
                    out.summary = 'This account has a Fit Score of ' +
                        (out.fitScore != null ? String.valueOf(out.fitScore) : 'unknown') +
                        (String.isNotBlank(out.industry) ? (' in the ' + out.industry + ' industry') : '') +
                        ', based on the latest Data Cloud calculated insight run.';
                } else {
                    out.isSuccess = false;
                    out.summary = 'No Fit Score insight has been calculated for this account yet.';
                }
            } catch (Exception e) {
                out.isSuccess = false;
                out.summary = 'Unable to retrieve the Fit Score right now (' + e.getMessage() + ').';
            }

            results.add(out);
        }

        return results;
    }
}