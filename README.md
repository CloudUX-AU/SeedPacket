![Planting Seeds](https://github.com/CloudHugger/CUX_SeedPacket/blob/master/seeddata.jpeg)

# SeedPacket: 
## A way to generate realistic seed data for your Salesforce Orgs

If you want realistic test and demo data for your Salesforce orgs but cant stand the thought of having to create it ... yet again! ... then this utility might be of interest! Read on...

### Why create yet another way to generate Salesforce seed data? ###

When I say 'seed data' Im talking about creating data for the purpose of enabling realistic testing and effective demonstration of the awesome work you do in your Salesforce orgs. 

Of course there are already plenty of ways out there already to create seed data. There's test factories that pump out similarly named records and the old 'roll it yourself' approach of creating contacts called test1, test2 etc. Paid apps too. This approach I've used to create SeedPacket I haven't seen before so it'd be good to hear your thoughts on it. Feel free to ping me via linkedin https://www.linkedin.com/in/carlvescovi/ if you've any feedback to share.

Personally I really want - and think we'd all benefit from having - data that is as close in look, feel, touch and smell to production data as possible, without being production data of course. I think most developers would prefer that too if there was an easy way to generate it.  Finding a simple way to do this has annoyed me for over a decade!

In the roles I perform test or demo data that reads as 'Contact1 one','test test' and 'fffur fdgkj' is not adequate; it doesn't present well, doesn't replicate production conditions and isn't really very useful . Your stakeholders (and you) don't want to see that junk data and good luck getting your dashboards and reports to present realistically.  Test data ideally should replicate production as closely as possible and to achieve that takes time and effort that isn't easy to justify. Test factories just like spambots will populate all fields - users don't.  Test factories use increments to name people - users don't. Hand rolled test data becomes out of date quickly. There has to be a better way!  I started pondering the word 'seed' and an idea began to 'grow'... (see what I did there?)

### So what is different about this approach? ###

This approach to generating test data was inspired by nature and aspires to provide the following benefits:

- Real world names for de-identification logic - yay!
- Consistently inconsistent data, just like production - yay!
- Ability to 'bump' date fields so your new seed data is always relevant for reporting, dashboarding etc - yay!
- Can be run via the SandboxPostCopy interface too if you want - yay!
- Can be used in test classes too to create realistic data - amazing!
- Can regenerate new test data to reflect current timeframe with a single command! - whoa yay!
- Supports creating multiple datasets depending on your use case ie. one for development purposes and one for demo's. Prepare as many as you need to support your use cases - incredible!
- A single file has been tested to thousands of records which should be sufficient for most dev and demo org use. If you need more then you could just string a few `SeedPacket.plantSeedPacket` statements together to build more complex datasets.

### Thats selling the dream... so how does it work? ###

In short, SeedPacket tackles this challenge differently to most (all I think) other Ive seen. SeedPacket once installed to a source data org (dont worry - very small footprint of a few files) enables creation of 'SeedPackets' via consumption of simple definition file you create. The definition file enables you to nominate a subset of related (or unrelated - your call) source records from that org, spanning as many objects as you want (infinite is probably not possible, but I haven't tested so who knows it might work!) in order of dependency. SeedPacket packages up the information it needs into a single 'SeedPacket' file which is promptly emailed to you by your org. Its readable so feel free to inspect and modify it. You then store that SeedPacket file as a single Static Resource in whatever org you spin sandboxes off (if you want it automatically copied to new sandboxes moving forward), or even straight to a target org - its up to you. SeedPacket creation only needs to happen once for a dataset. Now, every time you create a new sandbox the SeedPacket file is also copied over and then you execute the 'plantSeedPacket' command.  SeedPacket retrieves the SeedPacket file you nominate and incrementally inserts the records in order of dependency linking them up as it goes. Taddah! Mmmm the sweet smell of fresh seed data!

### But we cant have production data exposed outside of Production! ###

Yeah me either and that'd not be smart! Thats why I baked in a way for you to de-identify names, phone numbers, email addresses and dates at the point of the SeedPacket being generated. This way, no identifiable data ever leaves production. You can add additional de-identification logic if you need. Its open source so do with it what you wish :)

Thus - using this approach some simple configuration can ensure the records extracted will be just **like** real data with all its glorious quality errors, completeness problems, typos etc but not **BE** real data. 

### Limitations ###

I've not invested thousands of test hours into this so its limits aren't clear to me.  I did test it with approximately 4000 records across two objects which is about as many records as you'd expect in a reasonably full dev org.  I anticipate the compute time might be the biggest constraint depending on what you're expecting out of the SeedPacket logic.

At time of writing field names are case sensitive in the definition file, and it uses SOQL so all the expected limits apply there too.  Currently 'bump' only handles date fields, not datetime - might get to that.

## Ok so I have installed the SeedPacket components - now what?

**Step 1 - create a definition file**

Heres an example to get you started.

	[
		{
		"description":"get contacts and de-identify them",
		"name":"contactsList",
		"datatable":"contact",
		"query":"LIMIT 1000",
		"params" : {
			"deidentify" : "FirstName:FIRSTNAME,LastName:LASTNAME,Phone:PHONE,Email:EMAIL,Birthdate:DATE",
			"bump" : "Signup_Date__c"
			}
		},
		{
		"description":"get tasks from those contacts",
		"name":"tasks",
		"datatable":"task",
		"query":"where WhoId in [[contactsList.Id]]",
		"params" : {
			"bump" : "ActivityDate"
			}
		}
	]

You save this as a .json file and then save that file into Static Resources in the org that you're scraping seed data from. Its an array with each array element describing a data retrieval and processing step. One or more steps will result in a SeedPacket file that is later used to recreate the data in your target org.

* **description** is optional and not used; its just there to remind you of what the step is doing.
* **name** is the name of the step. Keep this unique and you can reference it later in subsequent queries to retrieve related data. More on that later.
* **datatable** is the object you want to retrieve data from.
* **query** is the query criteria to apply to the SOQL statement. You can use any valid SOQL from 'WHERE' onwards. Note the double brackets. More on that later.
* **params** is optional and how you include additional instructions to execute in the SeedPacket creation.

**What are Params ?**

Params currently provides you access to two configurable options - **deidentify** and **bump**


**deidentify**

To de-identify is to change the source data such that it cannot readily be linked back to an individual. Note that if a source field is blank it will be left blank. SeedPacket wont populate any fields that are blank in the source data.

* **deidentify** is passed a string of comma separated key value pairs.  The key is a field from the object that you want to de-identify, and the value is the de-identification treatment type you want to apply. Ive provided some to get you going and you're welcome to add more!
	*FIRSTNAME* will replace the source data with a valid first name randomly selected from an accompanying list of about 200.
	*LASTNAME* will replace the source data with a valid last name randomly selected from an accompanying list of about 200.
	*PHONE* will randomly change numerical digits in the source phone number without changing non-numerical characters i.e brackets or spaces.
	*EMAIL* will blow away the source email address and replace it with an obviously dud but unique email address.
	*DATE* will randomly add + or - 90 days to the original date. So it will be different but hopefully still reasonably useful.

**bump**

To 'bump' a date field is to address the fact that seed data can get stale - you might want parts of your seed data that you plant to be more current.  By bumping nominated date fields you can tell the planting step to adjust a date field by an offset. The offset will be the difference in days between the date the SeedPacket was last updated, and the date that the SeedPacket.plantPacket command is issued against that SeedPacket. This way, using bump means your SeedPacket data can remain relevant to the timeframe it is planted in.

**What is the double bracket ie. `[[contactsList.Id]]` reference ?**

To work, SeedPacket relies on you retrieving data in order of dependency. So in this example you'd need to retrieve contacts before you can retrieve their related activities.

You can merge ids from a previous retrieval step into the subsequent data retrieval steps. This enables you to easily retrieve only related records. In this case the `[[contactsList.Id]]` part will result in a merge of a list of the record ids from the contactsList step.  If you want to use a different field just use the same notation ie. `[[contactsList.FirstName]]` would merge in a list of first names.  You can use multiple double bracket merges in a query statement if you wish ie. `WHERE ( Id in [[contactsList.Id]] or FirstName in [[contactsList.FirstName]])` would work as well.

**Pulling it all together**

So in the provided example above the following is done to define the SeedPacket:

 - a list of up to 1000 contacts is retrieved.
 - each contact then has its FirstName and LastName fields changed to a new random name, its Email address modified and the Phone field changed but formatting left intact.  The Birthdate field is adjusted to something similar but not the same.
 - a custom field 'Signup_Date__c' is tagged to be adjusted at planting (if is not null).
 - a list of Task records is then retrieved, and only those where the WhoId is one of the contactsList record Ids.
 - the standard field 'ActivityDate' is tagged to be adjusted at planting (if is not null).

**Step 2 - save as a Static Resource.**

Too easy. Lets say you named it 'seedling'.

**Step 3 - generate your SeedPacket!**

From the Debug Console just execute `SeedPacket.createSeedPacket('seedling');`

Assuming your file definition is interpreted correctly you'll be emailed a SeedPacket file. Hooray! It is in json format - take a look to see whats in it if you're interested.

**Step 4 - save your SeedPacket**

You can save it to the source org so that its copied into new sandboxes automatically, or just add it to a target org  that you want data seeded into as a Static Resource.  You're now ready to see high quality data to any org you want with a single command!

## Planting SeedPackets

Planting is easy.  Assuming you have installed the SeedPacket classes and stored your SeedPacket file  as a Static Resource you're good to go. You could do this for any number of SeedPackets you have stored in your target org.

Assuming you have saved your SeedPacket as a static resource named 'seedlings'
Just use the Developer Console to execute `SeedPacket.plantSeedPacket('seedlings');`

The Sandbox Post copy interface has also been included so feel free to do the same via a post copy Apex Class execute. The utility currently assumes your SeedPacket would be named 'seedling'. 