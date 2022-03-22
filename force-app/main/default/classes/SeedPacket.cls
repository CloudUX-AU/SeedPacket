/**
 * A simple data seeding class
 * Two methods - 
 * 'create' : to prepare a definition file or 'SeedPacket' that once stored in an org can generate useful seed data with a single command.
 * 'plant' : to execute logic that will seed data that has been captured and packaged up using the 'create' method.
 * All data that is inserted needs to be held within the SeedPacket.
 * SeedPacket is assumed to be stored as a Static Resource.
 * 
 */
public with sharing class SeedPacket {
    
    /**
     * these are the only standard objects that will be included in the scope of the seedpacket prep
     * ADD MORE AS YOU REQUIRE
     */
    private static Set<string> standardObjectInclusions {
        get{
            return new Set<String>{'Account','Contact','Asset','AccountContactRelation'} ;
        }
    }
    
    public class SeedPacketException extends Exception {}

    private static Boolean runningInASandbox {
        get {
            if (runningInASandbox == null) {
                runningInASandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
            }
            return runningInASandbox;
        }
        set;
    }

    /** 
     * clear out data if rerunning packet insertion - attempts object deletion in reverse order of insertion.
     * only permitted if is a sandbox!
     */
    public static void resetData(String seedPacketName){
        if(runningInASandbox){
            StaticResource sr = getSeedPacket(seedPacketName);
            Packet pkt = 
                        (Packet)JSON.deserialize(sr.Body.toString(), Packet.class);
            for(integer i= pkt.steps.size() - 1; i>=0; i--){
                List<SObject> records = Database.query('Select id from '+ pkt.steps[i].datatable);
                Database.DeleteResult[] delResult = Database.delete(records, false);
            }
        }
    }

    /**
     * modify a username to make consistent across orgs regardless of prod or sandbox
     * @param un the username to consider modifying
     */
    private static string baseUserName(String un){
        String postAt = un.substringAfter('@').substringBefore('.'); // domain in user name
        return un.substringBefore('@') + '@' + postAt; 
    }
    
    /**
     * Create method is used to prepare a SeedPacket file that 
     * once stored as a Static Resource can be used to quickly and 
     * repeatedly seed data into orgs for development, testing etc.
     * 
     * @param seedPacketName is the name of the Static Resource definition file to use
     */
    public static void createPacket(String seedPacketName){
        Packet p = createPacketPayload(seedPacketName,null);
        sendEmail(JSON.serializePretty(p,true));
    }

    /**
     * Create method is used to prepare a SeedPacket file that 
     * once stored as a Static Resource can be used to quickly and 
     * repeatedly seed data into orgs for development, testing etc.
     * this variant lets a user provide a starting query and Seedpacket figures out the rest.
     * @param seedpacketQuery is the query used to kick off the seeding process 
     */
    public static void autoCreatePacket(String seedpacketQuery){
        Packet p = createPacketPayload(null,seedpacketQuery);
        sendEmail(JSON.serializePretty(p,true));
    }

    /**
     * replaces recordtypeIds with developername references, so reliably mapped when in target org
     * replaces user Ids with usernames
     */
    public static Packet removeSeedpacketIds(Packet seedpacket){
        String pktString = JSON.serialize(seedpacket);
        for(Recordtype rt : [SELECT Id, SObjectType, DeveloperName FROM RecordType]){
            pktString = 
                pktString.replace(String.valueOf(rt.Id),'__rt__'+(rt.SObjectType+rt.DeveloperName).toLowerCase());
        }
        for(User u : [SELECT Id, Username from User]){
            // adapt username if is a sandbox
            pktString = pktString.replace(String.valueOf(u.Id), '__usr__'+ baseUserName(u.Username).toLowerCase());
        }
        return (Packet)JSON.deserialize(pktString, Packet.class);
    }

    /**
     * replacement ids for user and record type ids
     */
    private static Map<string,string> referenceReplacements {
        get{
            if(referenceReplacements == null){
                referenceReplacements = new Map<string,string>();
                for(Recordtype rt : [SELECT Id, SObjectType, DeveloperName FROM RecordType]){
                    referenceReplacements.put('__rt__'+(rt.SObjectType+rt.DeveloperName).toLowerCase(),String.valueOf(rt.Id));
                }
                for(User u : [SELECT Id, Username from User]){
                    referenceReplacements.put('__usr__'+baseUsername(u.Username).toLowerCase(), String.valueOf(u.Id));
                }
            }
            return referenceReplacements;
        }
        private set;
    }

    public static Ingredient restoreSeedpacketIds(Ingredient i){

        // will try to process only at field level to limit heap size
        // get list of fields
       
        for(sobject o : i.records){
            for(string fld : i.typeMap.get('REFERENCE').removeEnd(',').split(',')){
                if(fld > '' && referenceReplacements.containsKey((String)o.get(fld))){ 
                    o.put(fld,referenceReplacements.get((String)o.get(fld)));
                }
            }
        }
        return i;
    }
    
    /**
     * Primary create logic herein
     * @param seedPacketName is the name of the Static Resource definition file to use
     * @param autogenQuery if not null, is a query that SeedPacket can autogenerate a payload from
     */
    @TestVisible
    private static Packet createPacketPayload(String seedPacketName, String seedPacketQuery){
        try{
            Packet seedpacket = new Packet();
            seedpacket.createdDate = date.today();
            List<String> emptyList = new List<String>();
            
            Datetime contextDateTime;
            if(seedPacketQuery == null && seedPacketName != null){
                StaticResource sr = getSeedPacket(seedPacketName);
                seedpacket.steps = 
                    (List<Step>)JSON.deserialize(sr.Body.toString(), List<Step>.class);
                contextDateTime = sr.lastModifiedDate;
            } else if(seedPacketQuery != null && seedPacketName == null){
                // auto build seedpacket.steps prior to processing further
                seedpacket.steps = generateSeedPacketSteps(seedPacketQuery);
                contextDateTime = Datetime.now();
            }
            // pull together the data - generate fields dynamically
            Map<string, List<sobject>> listsByName = new Map<string, List<Sobject>>();
            Map<string, string> ids = new Map<string, String>();
            Integer stepIndex = 0;
            for(Step s : seedpacket.steps){
                // run query
                stepIndex++;
                Map<string,string> objectDetails = getFields(s.datatable);
                string q = objectDetails.get('query')+' '+s.query; // query for all createable fields AND append query scope
                
                while(q.contains('[[')){ // find & replace the ids to be merged into query string if any
                    string m = q.substringAfter('[[').substringBefore(']]');
                    string key = '[[' + m + ']]';
                    // build set and store into Ids map
                    if(!ids.containsKey(key)){
                        throw new SeedPacketException(
                            'query is referencing a step that doesnt exist. Check your definition file.'
                        );
                    }
                    if(!ids.containsKey(key) 
                        && listsByName.containsKey(m.substringBefore('.'))){ // build the set of ids as a string that can be merged into query string
                        string f = '(';
                        for(sobject o : listsByName.get(m.substringBefore('.'))){
                            Id k = (Id)o.get(m.substringAfter('.'));
                            f += (k != null) ? '\'' + k + '\',' : '';
                        }
                        f = f.removeEnd(',')+')';
                        ids.put(key, f.replace('()',':emptyList')); // bind variable avoids runtime error 
                    } 
                    // merge list of ids into query string
                    q = q.replace(key, ids.get(key));
                }
                
                
                Map<Id, Sobject> query = new Map<Id, Sobject>(Database.query(q));
                query = processParams(contextDateTime, s,query); // this step addresses bump and deidentification processing
                listsByName.put(s.name, query.values());
                if(query.values().size() > 0 && !s.name.startsWith('READONLY__')){ // only add an ingredient if there are records to process
                    Ingredient i = new Ingredient();
                    i.records = query.values();
                    i.totalRecords = i.records.size();
                    i.name = s.name;
                    i.typeMap = objectDetails;
                    s.query = q; // the final merged query with ids where used to limit scope
                    s.queryLength = q.length();
                    seedpacket.ingredients.add(i);
                }
            }
            seedpacket = removeSeedpacketIds(seedpacket); // replace hardcoded recordtype and user ids with placeholders
            return seedpacket;
        } catch (exception e){
            throw e;
        }
    }

    /**
     * auto generate steps and send via email
     */
    public static void generateAndSendSeedPacketSteps(String query){
        List<Step> steps = generateSeedPacketSteps(query);
        sendEmail(JSON.serializePretty(steps));
    }

    /**
     * auto generate steps prior to processing
     * @param query the initial query to start building steps from
     */
    @TestVisible
    public static List<Step> generateSeedPacketSteps(String query){
        List<Step> steps = new List<Step>();
        Integer stepNumber = 0; // default
        
        // assumes user has provided a legit query or will error out
        String obj = 
            query.tolowercase().substringAfter('from').substringBefore('where').trim();
        // set the initial step
        steps.add(new Step('initial query','step0',obj, query.tolowercase().substringAfter(obj)));
        
        /**
         * ``get child relationships
         * ``build query - use map to consolidate where clauses by object
         * ``note child objects - aggregate where clauses around object
         * build steps for each object and where query
         * for each of the new steps go through the process above
         * crawl through steps until no further to go...
         */
        Boolean moreRelationshipsToAssess;
         
        do {
            moreRelationshipsToAssess = false; // default unless proven otherwise
            obj = steps[stepNumber].datatable;
            // get child relationships
            Schema.ChildRelationship[] children = 
                Schema.getGlobalDescribe().get(obj).getDescribe().getChildRelationships();
            Map<string, string> whereClausesByObject = new Map<string, string>();
            // consolidate scope by child object into query WHERE clauses
            for(Schema.ChildRelationship rel : children){
                String relationshipObject = rel.getChildSObject().getDescribe().getName();
                String relationshipField = rel.getField().getDescribe().getName();
                Boolean fieldIsCreateable = rel.getField().getDescribe().isCreateable();
                Boolean fieldIsFilterable = rel.getField().getDescribe().isFilterable();
                Boolean objectIsRelevant = ( rel.getChildSObject().getDescribe().isCustom() 
                                            && !rel.getChildSObject().getDescribe().isCustomSetting()  // exclude custom setting
                                            && !relationshipObject.endsWith('__b') ) // exclude big objects 
                                            || standardObjectInclusions.contains(relationshipObject);
                                       
                String relationship = rel.getRelationshipName();    
                if(fieldIsCreateable && objectIsRelevant && fieldIsFilterable){
                    String clause = (whereClausesByObject.containsKey(relationshipObject)) ?
                        whereClausesByObject.get(relationshipObject) + ' OR ' : '';
                    // append relationship so query scope is extended selectively IF the field is createable
                    clause += relationshipField + ' IN [[step' + stepNumber + '.Id]]';
                    whereClausesByObject.put(relationshipObject, clause);
                }
            }
            // create steps
            for(string childObj : whereClausesByObject.keySet()){
                if(childObj != obj) { // avoid cyclic relationships
                    moreRelationshipsToAssess = true;
                }
                steps.add(new Step('autogenerated ' + childObj +' step',
                                    'step'+ (steps.size()),
                                    childObj, 
                                    'WHERE ' + whereClausesByObject.get(childObj) + ' LIMIT 50')
                ); // aggregatedIds is appended to ensure records are not queried more than once
            }
            stepNumber += (moreRelationshipsToAssess) ? 1 : 0;
        } while (
            moreRelationshipsToAssess // crawl down the steps until there are no more child relationships to assess
        );
        // sort final query length
        for(Step st : steps){
            st.queryLength = (st.query > '') ? st.query.length() : 0;
        }
        return steps;
    }

    /**
     * Process any params to handle date/datetime 'bump' and string/email/phone 'scramble' requests
     * date d is from the static resource - lastmodifieddate
     * 
     */
    private static Map<Id,SObject> processParams(Datetime dt, Step step, Map<Id, Sobject> query){
        Integer offset = 0; // default
        List<string> offsetFlds = new List<String>();
        Map<string,string> deidentifyPairs = new Map<string,string>();
        
        if(step.params != null && step.params.containsKey('deidentify')){ // prep for the field:type pairs
            // eg firstname:FIRSTNAME,lastname:LASTNAME,phone:PHONE,email:EMAIL,dateofbirth:DATE
            for(String pair : step.params.get('deidentify').split(','))
                deidentifyPairs.put(pair.split(':')[0],pair.split(':')[1]);
        }
        
        // loop through records and make changes if requested
        for(SObject record : query.values()){
            // process bump requests if any
            for(String fld : offsetFlds){
                if(record.get(fld) != null)
                    record.put(fld, ((Date)record.get(fld)).addDays(offset));
            } 
            // process deidentify requests if any
            integer prefix = 1;
            for(String fld : deidentifyPairs.keySet()){
                if(record.get(fld) != null){ // only action if there is a value in the field
                    switch on deidentifyPairs.get(fld).toLowerCase() { // act based on type of action requested
                        when 'firstname','lastname' { // replace with a new first name
                            record.put(fld, 
                            namesResource.get(deidentifyPairs.get(fld).toLowerCase())[(math.random() *(namesResource.get('firstname').size()-1)).intValue()].toLowerCase().capitalize());
                        }
                        when 'email' { // scramble the email address
                            string em = (String)record.get(fld);
                            record.put(fld, String.valueOf(prefix)+String.valueOf(Datetime.now().getTime())+'@newemail.com');
                            prefix ++; // ensures uniqueness on each cycle
                        }
                        when 'phone' { // change numbers without changing format to keep localised
                            string ph = (String)record.get(fld);
                            string newph = '';
                            for(integer i=0; i<ph.length()-1; i++){
                                newph += (ph.mid(i,1).containsAny('0123456789')) ?
                                    String.valueOf((math.random()*9).intValue()) : ph.mid(i,1);
                            }
                            record.put(fld, newph);
                        }
                        when 'date' { // adjust date by up to say 90 days either side to keep close to realistic
                            record.put(fld, ((Date)record.get(fld)).addDays(((math.random()*180)-90).intValue()+1));
                        }
                    }
                }
            }
        }
        return query;
    }
    /**
     * names resource that is used to deidentify production data
     */
    private static Map<string,List<string>> namesResource {
        get{
            if(namesResource == null){
                namesResource = new Map<string, List<String>>();
                String names = [select id, body 
                                FROM StaticResource 
                                WHERE name = 'namesResource' LIMIT 1].Body.toString();
                namesResource = (Map<string,List<String>>)JSON.deserialize(names, Map<string,List<String>>.class);
            }
            return namesResource;
        }
        private set;
    }

    /**
     * result email
     */
    public static void sendResultEmail(string resultString){
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage(); 
        email.setSubject( 'Your data seeding results are in...' );
        email.setToAddresses( new String[] {/*UserInfo.getUserEmail()*/ 'c.vescovi-ext@traxens.com'} );
        email.setPlainTextBody(resultString);
        if(!Test.isRunningTest()) {
            Messaging.SendEmailResult [] res = 
            Messaging.sendEmail(new Messaging.SingleEmailMessage[] {email});
        }
    }
    /**
     * send email to context user with results appended
     */
    private static void sendEmail(string seedPacketString){
        // send result as an email attachment to user email address
        String body = 'This attachment has all the information required to seed data into another org.';
        body += '\n\nTo use this, save the attachment as a static resource in the org you want to seed data into.';
        body += '\n\nOnce you have done that, then you can use the SeedPacket.plant method and watch your data grow!';
        body += '\n\nBe aware of and possibly disable automations that may interfere with the seeding process.';

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage(); 
        Messaging.EmailFileAttachment fileAttachment = new Messaging.EmailFileAttachment();
        fileAttachment.setFileName('SeedPacket_result.json');
        fileAttachment.setBody(Blob.valueOf(seedPacketString));
        email.setSubject( 'Your Seed Packet is attached!' );
        email.setToAddresses( new String[] {UserInfo.getUserEmail()} );
        email.setPlainTextBody(body);
        email.setFileAttachments(new Messaging.EmailFileAttachment[] {fileAttachment});
        
        if(!Test.isRunningTest()) {
            Messaging.SendEmailResult [] res = 
                Messaging.sendEmail(new Messaging.SingleEmailMessage[] {email});
        }
    }

    /*
    * variables to be accessed via sync or async processing
    */
    //public static Map<string, SObject> recordsByOldId { get; set; }
    //public static integer stepIndex { get; set;}
    public static Set<Id> retrievedRecordIds {get; set;}
    public static String insertResult {get; set;}
    //public static Packet SeedPacket {get; set;}
    public static Set<string> ignores = new Set<string>{'recordtypeid'}; // these are reference fields to ignore as the references will be consistent
    //public static Integer dateOffset {get; set;}
    //public static string seedPacketName {get;set;}

    /**
     * generates the seed data from the resource file.
     * @param seedPacketName name of the static resource seedpacket file to retrieve and process
     * makes adjustments to nominated dates and lookup fields prior to insert
     */ 
    public static void plantSeedPacket(string seedPacketName){
        if(!runningInASandbox && !Test.isRunningTest()) 
            system.assertEquals(true,false,'Dont plant seedpackets in production.');
        
        
        String insertResult = 'The following happened during the seeding process:\n\n';
        
        Savepoint sp = Database.setSavepoint();
        
        // insert the records
        // before inserting the next batch run a find replace on the old ids
        StaticResource sr = getSeedPacket(seedPacketName);
        Packet seedPacket = (Packet)JSON.deserialize(sr.Body.toString(), Packet.class);
        Integer dateOffset = date.today().daysBetween(seedPacket.createdDate);
        // loop through ingredients
        Integer stepIndex = 0;
        Map<string, SObject> recordsByOldId = new Map<string, SObject>();
        retrievedRecordIds = new Set<Id>();

        
        
        
        for(integer i=0; i<seedpacket.ingredients.size();i++){ // process one object type at a time
            try{
                Ingredient ing = new Ingredient();
                ing = seedPacket.ingredients[i];
                ing = restoreSeedpacketIds(ing);
                recordsByOldId = insertIngredients(seedpacket.steps[stepIndex], ing, stepIndex, insertResult, dateOffset, recordsByOldId);
            } catch (exception e){
                insertResult += '\n\nError occured at step '+stepIndex+':'+ e.getMessage();
                Database.rollback(sp);
                break;
            }
            stepIndex ++;
        }
        sendResultEmail(insertResult);
    }
    
    /**
     * process an Ingredient into inserted records
     */
    public static Map<string,SObject> insertIngredients(Step s, Ingredient i, Integer stepIndex, String insertResult, Integer dateOffset, Map<string, sobject> recordsByOldId){
        String objectName = i.records[0].getSObjectType().getDescribe().getName();
        insertResult = insertResult + '** seeding step number '+stepIndex+' '+ objectName+':\n\n';
        // need to retrieve the bump field info if exists
        List<String> offsetFlds = new List<String>();
        if(s.params != null && 
            s.params.containsKey('bump')){ // prep to bump dates based on an offset
            offsetFlds = s.params.get('bump').split(',');
        }
        
        // prep records - note old Ids and then null them ready for insert to new org
        // ignore records that have already been processed and inserted in previous steps
        List<SObject> revisedRecordsList = new List<SObject>();
        for(SObject oo : i.records){
            SObject o = oo.clone(true,true,true,true);
            Id originalId = (Id)o.get('Id');
            if(!retrievedRecordIds.contains(originalId)){
                // store old id to use as a reference later
                retrievedRecordIds.add(originalId);
                o.put('Id', null);
                
                // cycle through any reference fields and update to the new Ids where available
                // order of dependency used at packet creation means we rely on mappings from previous steps being available in this step
                // some we ignore, like recordtype
                // bump dates as requested
                for(string fld : offsetFlds){
                    if(o.get(fld) != null)
                            o.put(fld,((Date)o.get(fld)).addDays(dateOffset)); // bump date field prior to insert
                }

                /** if we have a new id to switch in great, 
                 * otherwise will need to leave field empty to avoid cross reference error
                 */
                for(string fld : i.typeMap.get('REFERENCE').replaceAll('recordtypeid,','').removeEnd(',').split(',')){
                    
                    if(!ignores.contains(fld) && fld > ''){
                        string oldId = (String)o.get(fld);
                        if(recordsByOldId.containsKey((String)o.get(fld))){
                            o.put(fld, recordsByOldId.get((String)o.get(fld)).get('Id')); // switch old reference Id for the new Id where it exists
                        } else {
                            if(fld.toLowerCase() == 'ownerId') { 
                                o.put(fld, UserInfo.getUserId()); 
                                insertResult += '\nhad to set owner to context user';
                            } // have to link to context user if cant find original owner
                            else {
                                insertResult += '\nhad to set reference field \''+fld+'\'to blank';
                                o.put(fld, ''); // nothing to link to
                            }
                        }
                    }
                }
                recordsByOldId.put(originalId,o);
                revisedRecordsList.add(o);
            } // else, ignore this duplicate
        }

        // prepped list of records so insert
        
        insertResult += 'Attempting to insert a batch of records...\n\n';
        Database.SaveResult[] srList = Database.insert(revisedRecordsList, false); // allow partial failure for logging purposes
        Boolean errorOccured = false;
        for (Database.SaveResult result : srList) {
            if (result.isSuccess()) {
                // Operation was successful, so get the ID of the record that was processed
                insertResult += '\nSuccessfully inserted record with Id '+result.getId();
                
            }
            else {
                // Operation failed, so get all errors   
                insertResult += '\nError occured:';             
                for(Database.Error err : result.getErrors()) {
                    String recId = (err.getMessage().indexOf('id value of incorrect type:') != -1) ?
                        err.getMessage().substringAfter('id value of incorrect type:').trim() : '';
                    String recType = (recId != '') ? recordObjectType(recId) : '';
                    insertResult += err.getStatusCode()+'-> '+ err.getMessage();
                    insertResult += '\nFields that affected this error: '+err.getFields();
                }
            }
        }
        return recordsByOldId;
    }


    private static string recordObjectType(String recId){
        return (recId > '') ? ((Id)recId).getSObjectType().getDescribe().getName() : '';
    }

    /**
     * this returns a map containing details of fields by type and the final query string. 
     * the types are referenced during planting phase
     */
    public static Map<string,string> getFields(string obj){
        String query = 'SELECT ';
        Set<string> ignores = new Set<string>{'id','recurrenceactivityid','masterrecordid','reportstoid','individualid','createddate','lastmodifieddate','systemmodstamp','createdbyid','lastmodifiedbyid','lastcurequestdate','lastcuupdatedate','lastvieweddate','lastreferenceddate','emailbounceddate'};
        Map<string,string> results = new Map<string,string>();
        for(Schema.DisplayType t : Schema.DisplayType.values()){
            results.put(t.name(), '');
        }
        Map<String, Schema.SObjectField> objectFields = 
            Schema.getGlobalDescribe().get(obj).getDescribe().fields.getMap();

        // Grab the fields from the describe method and append them to the queryString one by one.
        for(String s : objectFields.keySet()) {
            if(!ignores.contains(s.toLowerCase())){
                if(objectFields.get(s).getDescribe().isCreateable() || s.toLowerCase() == 'accountid' || s.toLowerCase() == 'parentId') { 
                    query +=  s + ','; // if want only those fields that are creatable returned
                    string types = results.get(objectFields.get(s).getDescribe().getType().name());
                    results.put(objectFields.get(s).getDescribe().getType().name(), types + s + ',');
                }
            }
        }
        results.put('query',query + 'Id FROM '+obj); // stash
        return results;
    }

    /** 
     * gets seedpacket static resource
     */
    public static StaticResource getSeedPacket(string seedPacketName){
        return [SELECT Id,
                    Name,
                    Body,
                    lastmodifieddate 
                    FROM StaticResource 
                    WHERE Name =:seedPacketName LIMIT 1];
    }

    /**
     * wrapper class
     */ 
    public class Packet{
        public Date createdDate {get;set;}
        public List<Step> steps {get;set;}
        public List<Ingredient> ingredients {get;set;}
        public Packet(){
            this.steps = new List<Step>();
            this.ingredients = new List<Ingredient>();
            this.createdDate = Date.today();
        }
    }

    /**
     * wrapper class
     */
    public class Step {
        public string description {get;set;}
        public string name {get;set;}
        public string datatable {get;set;} // avoiding reserved words
        public string query {get;set;}
        public Integer queryLength {get; set;}
        public Map<string,string> params {get;set;}
        public Step(){
            this.description = '';
            this.name = '';
            this.datatable = '';
            this.query = '';
            this.queryLength = 0;
            this.params = new Map<string,string>();
        }
        public Step(string d,string n, string dt, string q){
            this.description = d;
            this.name = n;
            this.datatable = dt;
            this.query = q.replaceAll('"','\'');
            this.queryLength = this.query.length();
            this.params = new Map<string,string>();
        }
    }

    /**
     * wrapper class
     */
    public class Ingredient {
        public List<Sobject> records {get;set;}
        public string name {get;set;}
        public Map<string, string> typeMap {get;set;}
        public integer totalRecords {get;set;}
        public Ingredient(){
            this.records = new List<Sobject>();
            this.name = '';
            this.typeMap = new Map<string,string>();
            this.totalRecords = 0;
        }
    }
}
