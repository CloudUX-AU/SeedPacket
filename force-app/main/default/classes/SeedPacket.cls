/**
 * A simple data seeding class
 * Two methods - 
 * 'create' : to prepare a definition file or 'SeedPacket' that once stored in an org can generate useful seed data with a single command.
 * 'plant' : to execute logic that will seed data that has been captured and packaged up using the 'create' method.
 * All data that is inserted needs to be held within the SeedPacket.
 * SeedPacket is assumed to be stored as a Static Resource.
 * 
 */
public with sharing class SeedPacket implements SandboxPostCopy {
    

    /**
     * threw this in to enable seeding post sandbox refresh option if thats what is required
     * this example assumes name of SeedPacket resource is 'seedling'
     */
    public void runApexClass(SandboxContext context) {
        SeedPacket.plantSeedPacket('seedling'); // is default SeedPacket name - use whatever you want
    }

    /**
     * Create method is used to prepare a SeedPacket file that 
     * once stored as a Static Resource can be used to quickly and 
     * repeatedly seed data into orgs for development, testing etc.
     * 
     * @param seedPacketName is the name of the Static Resource definition file to use
     */
    public static void createPacket(String seedPacketName){
        Packet p = createPacketPayload(seedPacketName);
        sendEmail(JSON.serializePretty(p,true));
    }


    /**
     * Primary create logic herein
     * @param seedPacketName is the name of the Static Resource definition file to use
     */
    @TestVisible
    private static Packet createPacketPayload(String seedPacketName){
        try{
            Packet seedpacket = new Packet();
            seedpacket.createdDate = date.today();
            List<String> emptyList = new List<String>();

            StaticResource sr = getSeedPacket(seedPacketName);
            seedpacket.steps = (List<Step>)JSON.deserialize(sr.Body.toString(), List<Step>.class);
            
            // pull together the data - generate fields dynamically
            Map<string, List<sobject>> listsByName = new Map<string, List<Sobject>>();
            Map<string, string> Ids = new Map<string, String>();
            for(Step s : seedpacket.steps){
                // run query
                Map<string,string> objectDetails = getFields(s.datatable);
                string q = objectDetails.get('query')+' '+s.query; // query for all createable fields
                List<String> sets = new List<String>();
                while(q.contains('[[')){ // find the ids to be merged into query string if any
                    string m = q.substringAfter('[[').substringBefore(']]');
                    string key = '[[' + m + ']]';
                    // build set and store into Ids map
                    if(!Ids.containsKey(key)){ // build the set of ids as a string that can be merged into query string
                        string f = '(';
                        for(sobject o : listsByName.get(m.substringBefore('.'))){
                            f += '\'' + (Id)o.get(m.substringAfter('.')) + '\',';
                        }
                        f = f.removeEnd(',')+')';
                        Ids.put(key, f.replace('()',':emptyList')); // bind variable avoids runtime error 
                    }
                    // merge list if ids into query string
                    q = q.replace(key, Ids.get(key));
                }
                Map<Id, Sobject> query = new Map<Id, Sobject>(Database.query(q));
                query = processParams(sr.lastmodifieddate, s,query); // this step addresses bump and deidentification processing
                listsByName.put(s.name, query.values());
                Ingredient i = new Ingredient();
                i.records = query.values();
                i.name = s.name;
                i.typeMap = objectDetails;
                seedpacket.ingredients.add(i);
            }
            return seedpacket;
            
        } catch (exception e){
            system.debug('ERROR:' + e.getMessage());
            throw e;
        }
           
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
     * send email to context user with results appended
     */
    private static void sendEmail(string seedPacketString){
        // send result as an email attachment to user email address
        String body = 'This attachment has all the information required to seed data into another org.';
        body += '\n\nTo use this, save the attachment as a static resource in the org you want to plant data in.';
        body += '\n\nOnce you have done that, then you can use the SeedPacket.plant method and watch your data grow!';
        
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

    /**
     * generates the seed data from the resource file.
     * @param seedPacketName name of the static resource seedpacket file to retrieve and process
     * makes adjustments to nominated dates and lookup fields prior to insert
     */ 
    
    public static void plantSeedPacket(string seedPacketName){
        Set<string> ignores = new Set<string>{'recordtypeid'}; // these are reference fields to ignore as the references will be consistent
        Savepoint sp = Database.setSavepoint();
        // insert the records
        // before inserting the next batch run a find replace on the old ids
        StaticResource sr = getSeedPacket(seedPacketName);
        Packet seedPacket = (Packet)JSON.deserialize(sr.Body.toString(), Packet.class);
        Map<string, SObject> recordsByOldId = new Map<string, SObject>();
        Integer dateOffset = date.today().daysBetween(seedPacket.createdDate);
        // loop through ingredients
        integer stepIndex = 0;
        

        for(Ingredient i : seedpacket.ingredients){ // process one object type at a time
            // need to retrieve the bump field info if exists
            List<String> offsetFlds = new List<String>();
            if(seedPacket.steps[stepIndex].params != null && 
                seedPacket.steps[stepIndex].params.containsKey('bump')){ // prep to bump dates based on an offset
                offsetFlds = seedPacket.steps[stepIndex].params.get('bump').split(',');
            }
            
            // prep records - note old Ids and then null them ready for insert to new org
            for(SObject o : i.records){
                // store old id to use as a reference later
                string originalId = (Id)o.get('Id');
                o.put('Id', null);
                // cycle through any reference fields and update to the new Ids where available
                // order of dependency used at packet creation means we rely on mappings from previous steps being available in this step
                // some we ignore, like recordtype
                // bump dates as requested
                for(string fld : offsetFlds){
                    if(o.get(fld) != null)
                            o.put(fld,((Date)o.get(fld)).addDays(dateOffset)); // bump date field prior to insert
                }

                for(string fld : i.typeMap.get('REFERENCE').removeEnd(',').split(',')){
                    if(!ignores.contains(fld) && fld > ''){
                        string oldId = (String)o.get(fld);
                        if(recordsByOldId.containsKey((String)o.get(fld)))
                            o.put(fld, recordsByOldId.get((String)o.get(fld)).get('Id')); // switch old reference Id for the new Id where it exists
                    }
                }
                recordsByOldId.put(originalId,o);
            }
            // prepped list of records so insert
            try{
                insert i.records;

            } catch (exception e){
                Database.rollback(sp);
                System.debug('ERROR:'+e.getMessage());
                throw e;
            }
            stepIndex ++;
        }
    }
    
    /**
     * this returns a map containing details of fields by type and the final query string. 
     * the types are referenced during planting phase
     */
    private static Map<string,string> getFields(string obj){
        String query = 'SELECT ';
        Set<string> ignores = new Set<string>{'recurrenceactivityid','masterrecordid','reportstoid','individualid','createddate','lastmodifieddate','systemmodstamp','ownerid','accountid','createdbyid','lastmodifiedbyid','lastcurequestdate','lastcuupdatedate','lastvieweddate','lastreferenceddate','emailbounceddate'};
        Map<string,string> results = new Map<string,string>();
        for(Schema.DisplayType t : Schema.DisplayType.values())
            results.put(t.name(), '');
        Map<String, Schema.SObjectField> objectFields = 
            Schema.getGlobalDescribe().get(obj).getDescribe().fields.getMap();

        // Grab the fields from the describe method and append them to the queryString one by one.
        for(String s : objectFields.keySet()) {
            if(s != 'id' && !ignores.contains(s)){
                if(objectFields.get(s).getDescribe().isCreateable() ) { 
                    query +=  s + ','; // if want only those fields that are creatable returned
                }
                    
                string types = results.get(objectFields.get(s).getDescribe().getType().name());
                results.put(objectFields.get(s).getDescribe().getType().name(), types + s + ',');
                
            }
        }
        results.put('query',query + 'Id FROM '+obj); // stash
        return results;
    }

    private static StaticResource getSeedPacket(string seedPacketName){
        return [select Id,Name,Body,lastmodifieddate from StaticResource where Name =:seedPacketName limit 1];
    }

    // define
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

    

    public class Step {
        public string description {get;set;}
        public string name {get;set;}
        public string datatable {get;set;} // avoiding reserved words
        public string query {get;set;}
        public Map<string,string> params {get;set;}
        public Step(){
            this.description = '';
            this.name = '';
            this.datatable = '';
            this.query = '';
            this.params = new Map<string,string>();
        }
        public Step(string d,string n, string dt, string q){
            this.description = d;
            this.name = n;
            this.datatable = dt;
            this.query = q.replaceAll('"','\'');
            this.params = new Map<string,string>();
        }
    }

    public class Ingredient {
        public List<Sobject> records {get;set;}
        public string name {get;set;}
        public Map<string, string> typeMap {get;set;}
        public Ingredient(){
            this.records = new List<Sobject>();
            this.name = '';
            this.typeMap = new Map<string,string>();
        }
    }
}