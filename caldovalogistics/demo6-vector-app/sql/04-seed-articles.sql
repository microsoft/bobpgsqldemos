-- Seed articles used by reset_demo(). Idempotent: existing titles are refreshed.
INSERT INTO knowledge_hub.seed_article (title, category, content) VALUES
('Reefer unit failure response', 'Handling procedure',
 'If a refrigerated trailer stops cooling, confirm the setpoint, record the return-air temperature every 15 minutes, and photograph the controller display. When product temperature exceeds the shipper limit for more than 30 minutes, place a quality hold and transfer pallets to validated cold storage. Never restart a reefer that shows a compressor fault without a technician.'),
('Temperature excursion for vaccines', 'Handling procedure',
 'Vaccines must stay between 2 and 8 degrees Celsius. On any excursion, quarantine the lot, keep it refrigerated, and contact the manufacturer quality team with logger data before deciding whether product can be released. Do not discard product until the manufacturer responds.'),
('Lithium battery acceptance', 'Handling procedure',
 'Shipments containing lithium ion or lithium metal cells require a UN3480, UN3481, UN3090, or UN3091 mark, a state-of-charge declaration of 30 percent or less for air, and an emergency contact. Damaged, swollen, or recalled cells are forbidden on aircraft and must be isolated in a sand-filled drum.'),
('Damaged pallet intake', 'Handling procedure',
 'When freight arrives crushed, leaning, or with broken stretch wrap, photograph all four sides before unloading, note the damage on the delivery receipt, and rewrap only after the driver signs. Concealed damage must be reported to the carrier within five business days.'),
('Customs hold release', 'Handling procedure',
 'International freight held by customs needs the commercial invoice, packing list, bill of lading, and broker power of attorney. Upload documents to the broker portal, record the hold reference, and keep the container in bond until release is confirmed electronically.'),
('Northwind Air cargo cutoffs', 'Carrier note',
 'Northwind Air accepts general cargo until 18:00 local time and dangerous goods until 15:00. Pharma shipments need the cold chain tag at booking. Late tenders roll to the next flight with no penalty but lose guaranteed service.'),
('Fabrikam Freight driver detention', 'Carrier note',
 'Fabrikam Freight allows two hours of free time at pickup and delivery. Detention bills at 75 dollars per hour afterward and requires check-in and check-out timestamps in the dock log. Dispute detention within 10 days.'),
('Contoso Rail intermodal weights', 'Carrier note',
 'Contoso Rail limits 40-foot containers to 44,000 pounds of cargo and requires the verified gross mass before loading. Overweight boxes are pulled at the ramp and incur restacking fees.'),
('Denver hub cold room', 'Facility runbook',
 'The Denver hub (DEN1) has two validated cold rooms at 2 to 8 degrees Celsius with 40 pallet positions each, backup generator coverage, and continuous temperature monitoring. Book space through the cold chain desk; after-hours access requires the duty manager.'),
('Atlanta dock scheduling', 'Facility runbook',
 'Atlanta (ATL1) runs 24 dock doors. Inbound appointments are required for every live unload and must be booked 24 hours ahead. Drop trailers go to the north yard; hazardous materials use doors 21 through 24 only.'),
('Seattle severe weather plan', 'Facility runbook',
 'During snow or ice warnings, Seattle (SEA1) pauses yard moves above a 3 percent grade, staggers shifts, and pre-stages de-icer at every door. Temperature-sensitive freight is moved inside before road closures.'),
('Boston security seal checks', 'Facility runbook',
 'Boston (BOS1) verifies every inbound seal number against the bill of lading before breaking it. A mismatched or missing seal stops the unload, triggers a security report, and requires photos of the trailer doors and seal.')
ON CONFLICT (title) DO UPDATE
SET category = EXCLUDED.category,
    content = EXCLUDED.content;
